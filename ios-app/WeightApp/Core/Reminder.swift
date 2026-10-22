import Foundation
import UserNotifications

/// 每日称重提醒：本地通知（免费、不依赖推送服务，断网也会响）
enum Reminder {
    private static let id = "weight.daily.reminder"
    private static let enabledKey = "reminder.enabled"
    private static let hourKey = "reminder.hour"
    private static let minuteKey = "reminder.minute"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// 上次设置的时间（默认 07:30）
    static var savedTime: Date {
        var comps = DateComponents()
        comps.hour = UserDefaults.standard.object(forKey: hourKey) as? Int ?? 7
        comps.minute = UserDefaults.standard.object(forKey: minuteKey) as? Int ?? 30
        return Calendar.current.date(from: comps) ?? Date()
    }

    /// 开启或更新时间：请求授权 → 移除旧通知 → 注册每天重复
    static func schedule(hour: Int, minute: Int, completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            center.removePendingNotificationRequests(withIdentifiers: [id])

            let content = UNMutableNotificationContent()
            content.title = "该称体重啦"
            content.body = "每天同一时间称重，趋势才准。打开记一笔，30 秒搞定。"
            content.sound = .default

            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

            center.add(request) { error in
                let ok = error == nil
                if ok {
                    UserDefaults.standard.set(true, forKey: enabledKey)
                    UserDefaults.standard.set(hour, forKey: hourKey)
                    UserDefaults.standard.set(minute, forKey: minuteKey)
                }
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    static func disable() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UserDefaults.standard.set(false, forKey: enabledKey)
    }
}
