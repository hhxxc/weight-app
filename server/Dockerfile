# 体重记录后端 —— NAS Docker 部署
# 依赖 better-sqlite3（含原生模块），在 CI 云端编译（能拉基础镜像 + 有编译工具链）。
# 用 alpine 大幅减小镜像体积（NAS 走 Tailscale 出口下载慢，体积越小越稳）。
FROM node:20-alpine

WORKDIR /app

# better-sqlite3 原生模块需要编译工具链（alpine 用 musl）
RUN apk add --no-cache python3 make g++

# 先装依赖（利用缓存层）
COPY package.json ./
RUN npm install --omit=dev

# 编译完删掉工具链，减小体积
RUN apk del python3 make g++

COPY src ./src

ENV NODE_ENV=production
# 数据落盘到这个卷，NAS 上挂载持久化目录
ENV DATA_DIR=/data

EXPOSE 3000

CMD ["node", "src/index.js"]
