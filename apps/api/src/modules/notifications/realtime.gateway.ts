import { Logger } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { ConnectedSocket, MessageBody, OnGatewayConnection, OnGatewayInit, SubscribeMessage, WebSocketGateway } from '@nestjs/websockets';
import { Model } from 'mongoose';
import type { Server, Socket } from 'socket.io';
import { PermissionsService } from '../../common/authz/permissions.service';
import { InjectModel } from '../../database/model';
import { RealtimeService } from './realtime.service';

/**
 * WebSocket gateway (socket.io at /ws): notifications, approvals, live attendance and meeting signaling.
 * The handshake must carry a valid access token; rooms are joined only after permission checks.
 */
@WebSocketGateway({ path: '/ws', cors: { origin: true, credentials: true } })
export class RealtimeGateway implements OnGatewayInit, OnGatewayConnection {
  private readonly logger = new Logger('Realtime');

  constructor(
    private readonly jwt: JwtService,
    private readonly realtime: RealtimeService,
    private readonly perms: PermissionsService,
    @InjectModel('Session') private readonly sessions: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Meeting') private readonly meetings: Model<any>,
  ) {}

  afterInit(server: Server): void {
    this.realtime.attach(server);
  }

  async handleConnection(socket: Socket): Promise<void> {
    try {
      const token = String(socket.handshake.auth?.token ?? '');
      const p = await this.jwt.verifyAsync<{ sub: string; org: string; sid: string; typ: string }>(token);
      const [session, user] = await Promise.all([this.sessions.findById(p.sid).lean<any>(), this.users.findById(p.sub).lean<any>()]);
      if (p.typ !== 'access' || !session || session.revokedAt || !user || user.status !== 'active') throw new Error('unauthorized');
      const grants = await this.perms.grantsFor({ userId: p.sub, orgId: p.org, role: user.role, sessionId: p.sid, name: user.fullName }, user.permissionsVersion);
      const authz = PermissionsService.build(grants, user.role);
      socket.data = { userId: p.sub, orgId: p.org, authz };
      await socket.join(`user:${p.sub}`);
      if (authz.can('attendance', 'view', 'team')) await socket.join(`org:${p.org}:attendance`);
      // Rooms are still known while disconnecting (not after): tell meeting peers this one left.
      socket.on('disconnecting', () => {
        for (const r of socket.rooms) if (r.startsWith('meet:')) socket.to(r).emit('rtc:peer-left', { peerId: socket.id });
      });
    } catch {
      socket.emit('error', { code: 'UNAUTHENTICATED' });
      socket.disconnect(true);
    }
  }

  /** WebRTC signaling: only invited participants may join a meeting room. Media never passes the server. */
  @SubscribeMessage('rtc:join')
  async join(@ConnectedSocket() socket: Socket, @MessageBody() body: { roomId: string }): Promise<{ ok: boolean; peers?: string[] }> {
    const { userId, orgId } = socket.data ?? {};
    if (!userId) return { ok: false };
    const m = await this.meetings.findOne({ organizationId: orgId, roomId: body?.roomId, status: { $in: ['scheduled', 'live'] } }).lean<any>();
    const allowed = m && (String(m.organizerId) === userId || (m.participantUserIds ?? []).some((u: any) => String(u) === userId));
    if (!allowed) return { ok: false };
    const room = `meet:${body.roomId}`;
    const peers = [...((await socket.in(room).fetchSockets()) ?? [])].map((s) => s.id);
    await socket.join(room);
    socket.to(room).emit('rtc:peer-joined', { peerId: socket.id, userId });
    if (m.status === 'scheduled') await this.meetings.updateOne({ _id: m._id }, { $set: { status: 'live', startedAt: new Date() } });
    return { ok: true, peers };
  }

  @SubscribeMessage('rtc:signal')
  signal(@ConnectedSocket() socket: Socket, @MessageBody() body: { to: string; data: unknown }): void {
    const rooms = [...socket.rooms].filter((r) => r.startsWith('meet:'));
    if (!rooms.length || !body?.to) return;
    socket.to(body.to).emit('rtc:signal', { from: socket.id, data: body.data });
  }

  @SubscribeMessage('rtc:leave')
  async leave(@ConnectedSocket() socket: Socket, @MessageBody() body: { roomId: string }): Promise<void> {
    const room = `meet:${body?.roomId}`;
    socket.to(room).emit('rtc:peer-left', { peerId: socket.id });
    await socket.leave(room);
  }
}
