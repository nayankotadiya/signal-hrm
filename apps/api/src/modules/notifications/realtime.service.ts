import { Injectable } from '@nestjs/common';
import type { Server } from 'socket.io';

/** Thin wrapper so services can push events without depending on the gateway. */
@Injectable()
export class RealtimeService {
  private server?: Server;

  attach(server: Server): void {
    this.server = server;
  }

  toUser(userId: string, event: string, payload: unknown): void {
    this.server?.to(`user:${userId}`).emit(event, payload);
  }

  toUsers(userIds: string[], event: string, payload: unknown): void {
    if (!this.server || !userIds.length) return;
    this.server.to(userIds.map((u) => `user:${u}`)).emit(event, payload);
  }

  /** Organization-wide channels (live attendance board) are filtered by permission when joining. */
  toRoom(room: string, event: string, payload: unknown): void {
    this.server?.to(room).emit(event, payload);
  }
}
