import Foundation

/// 一条体重记录
struct WeightRecord: Identifiable, Codable, Equatable {
    var id: Int
    var date: String   // YYYY-MM-DD
    var kg: Double
    var note: String

    var dateObj: Date? {
        Self.dateFormatter.date(from: date)
    }

    /// BMI = 体重kg / (身高m)^2，需要身高；没有身高返回 nil
    func bmi(heightCm: Double?) -> Double? {
        guard let h = heightCm, h > 0 else { return nil }
        let m = h / 100.0
        return kg / (m * m)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// 一条饮食记录
struct MealRecord: Identifiable, Codable, Equatable {
    var id: Int
    var date: String
    var type: String      // breakfast/lunch/dinner/snack
    var content: String
    var kcal: Double?       // 卡路里（拍照识别时填）
    var protein_g: Double?
    var fat_g: Double?
    var carbs_g: Double?
    var image_url: String?

    var typeName: String {
        switch type {
        case "breakfast": return "早餐"
        case "lunch": return "午餐"
        case "dinner": return "晚餐"
        default: return "加餐"
        }
    }

    /// 卡路里展示（无则为空）
    var kcalText: String {
        guard let k = kcal, k > 0 else { return "" }
        return "\(Int(k.rounded())) 千卡"
    }

    /// 根据当前时间自动判断餐次：5-9 早餐 / 10-13 午餐 / 14-20 晚餐 / 其余加餐
    static func autoType(for date: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<10: return "breakfast"
        case 10..<14: return "lunch"
        case 14..<21: return "dinner"
        default: return "snack"
        }
    }
}

/// 用户资料
struct UserProfile: Codable, Equatable {
    var id: Int
    var username: String
    var nickname: String
    var height_cm: Double?
    var target_kg: Double?
}

/// 登录/注册返回
struct AuthResponse: Codable {
    var token: String
    var user: UserProfile
}

/// 体重列表响应
struct WeightListResponse: Codable {
    var items: [WeightRecord]
}

/// 单条体重响应
struct WeightItemResponse: Codable {
    var item: WeightRecord
}

/// 饮食列表响应
struct MealListResponse: Codable {
    var items: [MealRecord]
}

/// 单条饮食响应
struct MealItemResponse: Codable {
    var item: MealRecord
}

/// 通用错误响应
struct ErrorResponse: Codable {
    var error: String
}
