import Foundation

/// BMI 计算与解读（纯函数，便于测试）
enum BMI {
    /// 计算 BMI，kg / 身高m^2
    static func value(kg: Double, heightCm: Double) -> Double {
        let m = heightCm / 100.0
        return kg / (m * m)
    }

    enum Level: String {
        case underweight = "偏瘦"
        case normal = "正常"
        case overweight = "超重"
        case obese = "肥胖"

        var colorHex: String {
            switch self {
            case .underweight: return "5B9BD5"   // 蓝
            case .normal: return "4CAF50"        // 绿
            case .overweight: return "FF9800"    // 橙
            case .obese: return "F44336"         // 红
            }
        }
    }

    /// 中国标准 BMI 分级
    static func level(_ bmi: Double) -> Level {
        switch bmi {
        case ..<18.5: return .underweight
        case ..<24: return .normal
        case ..<28: return .overweight
        default: return .obese
        }
    }
}
