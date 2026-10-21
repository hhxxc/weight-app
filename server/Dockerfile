# 体重记录后端 —— NAS Docker 部署
# 依赖 better-sqlite3（含原生模块），需要在 Linux 容器里编译
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
