const dns = require('node:dns');
dns.setServers(['8.8.8.8', '8.8.4.4']);
const mongoose = require('mongoose');
const { randomBytes, scryptSync } = require('node:crypto');

function hashPassword(password) {
  const salt = randomBytes(16).toString('base64url');
  const hash = scryptSync(password, salt, 64).toString('base64url');
  return `scrypt$${salt}$${hash}`;
}

(async () => {
  const uri = 'mongodb+srv://bulletproofteamwork_db_user:Hsh3JErVTXLiJ4HP@signalhrm.sefnksr.mongodb.net/?retryWrites=true&w=majority&appName=signalhrm';
  for (const dbName of ['signal_hrm_prod', 'signal_hrm_dev', 'signal_hrm']) {
    console.log('\n================ DB:', dbName, '================');
    try {
      const conn = await mongoose.connect(uri, { dbName });
      const users = await conn.connection.db.collection('users').find({}).toArray();
      console.log('User count:', users.length);
      for (const u of users) {
        console.log(`- ${u.email} (Role: ${u.role}, Status: ${u.status})`);
      }
      
      const newHash = hashPassword('Nayan@2005');
      const r = await conn.connection.db.collection('users').updateMany({}, {
        $set: {
          passwordHash: newHash,
          mustChangePassword: false,
          passwordSetAt: new Date(),
          failedLogins: 0,
          lockedUntil: null,
          status: 'active'
        }
      });
      console.log('Password updated for all users to Nayan@2005. Modified:', r.modifiedCount);

      const otps = await conn.connection.db.collection('otps').find({}).sort({ createdAt: -1 }).limit(5).toArray();
      console.log('Latest OTP records in', dbName, ':', otps);
      await mongoose.disconnect();
    } catch (err) {
      console.error(`Error in ${dbName}:`, err.message);
    }
  }
})();
