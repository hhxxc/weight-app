# 体重记录后端 —— NAS Docker 部署
# 依赖 better-sqlite3（含原生模块），在 CI 云端编译（能拉基础镜像 + 有编译工具链）。
# 用 node:20-slim（Debian）：better-sqlite3 有对应 glibc 预编译，无需额外工具链，
# 实测镜像体积 79MB（alpine 需编译工具链，docker save 后反而更大，弃用）。
FROM node:20-slim

WORKDIR /app

# 先装依赖（利用缓存层）
COPY package.json ./
RUN npm install --omit=dev

COPY src ./src

ENV NODE_ENV=production
# 数据落盘到这个卷，NAS 上挂载持久化目录
ENV DATA_DIR=/data

EXPOSE 3000

CMD ["node", "src/index.js"]
