import Foundation

/// 全局默认配置
enum AppConfig {
    /// 默认服务器地址（NAS 公网 ddnsto 映射，家内外通用）
    static let defaultServer = "https://c2r2t8t4.x.ddnsto.com"

    /// 备用服务器地址（家里内网直连，公网穿透挂掉时自动顶替）
    static let defaultBackupServer = "http://192.168.31.198:18191"

    /// API 前缀（后端所有接口都在这下面）
    static let apiPrefix = "/api"

    /// token 存 Keychain 的 service 标识
    static let keychainService = "com.hhxxc.weight"
}
