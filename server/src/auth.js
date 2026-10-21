import jwt from 'jsonwebtoken';

// 生产环境务必通过环境变量注入；这里给个默认值方便本地起服务
const SECRET = process.env.JWT_SECRET || 'weight-app-dev-secret-change-me';
const EXPIRE = '90d';

export function sign(user) {
  return jwt.sign({ uid: user.id, username: user.username }, SECRET, { expiresIn: EXPIRE });
}

export function verify(token) {
  try {
    return jwt.verify(token, SECRET);
  } catch {
    return null;
  }
}
