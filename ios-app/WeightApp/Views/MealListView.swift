import SwiftUI

/// 饮食记录页（按日期分组，可切换日期、增删）
struct MealListView: View {
    @EnvironmentObject var state: AppState

    @State private var selectedDate = Date()
    @State private var showAdd = false
    @State private var showFoodRecognize = false
    @State private var showNutritionOCR = false
    @State private var showVoice = false
    @State private var showFrequent = false
    @State private var showSearch = false
    @State private var weekSummary: [String: APIClient.MealDaySummary] = [:]
    @State private var editingMeal: MealRecord?
    @State private var viewingImage: URL?
    @State private var showViewer = false

    private var dateStr: String { WeightRecord.dateFormatter.string(from: selectedDate) }
    private var dayMeals: [MealRecord] {
        // 当前日期已加载就直接用；否则先取该日缓存，切日期不闪空
        state.mealsDate == dateStr ? state.meals : state.cachedMeals(for: dateStr)
    }

    /// 当日营养合计
    private var dayTotal: (kcal: Double, protein: Double, fat: Double, carbs: Double) {
        var k = 0.0, p = 0.0, f = 0.0, c = 0.0
        for m in dayMeals {
            k += m.kcal ?? 0
            p += m.protein_g ?? 0
            f += m.fat_g ?? 0
            c += m.carbs_g ?? 0
        }
        return (k, p, f, c)
    }

    /// 每日热量目标：手动设置优先，否则按当前体重估算
    private var kcalTarget: Double? {
        state.user?.kcalTarget(currentKg: state.sortedDesc.first?.kg)
    }

    private var summaryBar: some View {
        VStack(spacing: 6) {
            if let target = kcalTarget, target > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(dayTotal.kcal.rounded()))")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(Theme.ink)
                        .monospacedDigit()
                    Text("/ \(Int(target)) 千卡\(state.user?.isKcalTargetCustom == true ? "" : " · 自动")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.inkTertiary)
                    Spacer()
                    if dayTotal.kcal > target {
                        Text("超出 \(Int((dayTotal.kcal - target).rounded()))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.warning)
                            .monospacedDigit()
                    } else {
                        Text("还剩 \(Int((target - dayTotal.kcal).rounded()))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.success)
                            .monospacedDigit()
                    }
                }
                ProgressView(value: min(1, max(0, dayTotal.kcal / target)))
                    .tint(dayTotal.kcal > target ? Theme.danger : Theme.brandBlue)
            } else {
                HStack {
                    Label("\(Int(dayTotal.kcal.rounded())) 千卡", systemImage: "flame.fill")
                        .foregroundColor(Theme.warning)
                    Spacer()
                    Text("去「我的」设置热量目标")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if !dayMeals.isEmpty {
                HStack(spacing: 14) {
                    Text("蛋白 \(Int(dayTotal.protein.rounded()))g")
                    Text("脂肪 \(Int(dayTotal.fat.rounded()))g")
                    Text("碳水 \(Int(dayTotal.carbs.rounded()))g")
                    Spacer()
                    Text("\(dayMeals.count) 条")
                }
                .font(.system(size: 11))
                .foregroundColor(Theme.inkTertiary)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 一周七天

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    private var mondayFirstCalendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2   // 周一开头
        return c
    }

    private var weekDates: [Date] {
        let cal = mondayFirstCalendar
        guard let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDate)) else {
            return [selectedDate]
        }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var weekKey: String {
        WeightRecord.dateFormatter.string(from: weekDates.first ?? selectedDate)
    }

    private var isCurrentWeek: Bool {
        weekDates.contains { Calendar.current.isDateInToday($0) }
    }

    private var weekRangeText: String {
        guard let a = weekDates.first, let b = weekDates.last else { return "" }
        return "\(Self.monthDayFormatter.string(from: a)) – \(Self.monthDayFormatter.string(from: b))"
    }

    private var weekBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text(weekRangeText)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.inkTertiary)
                Spacer()
                if !isCurrentWeek {
                    Button("回到今天") {
                        selectedDate = Date()
                        Haptics.tap()
                    }
                    .font(.caption)
                    .foregroundColor(Theme.brandDeep)
                }
            }

            HStack(spacing: 4) {
                Button { shiftWeek(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 44)
                        .contentShape(Rectangle())
                }
                ForEach(weekDates, id: \.self) { d in
                    dayChip(d)
                }
                Button { shiftWeek(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func dayChip(_ d: Date) -> some View {
        let key = WeightRecord.dateFormatter.string(from: d)
        let selected = key == dateStr
        let today = Calendar.current.isDateInToday(d)
        let kcal = kcalForChip(key)

        return Button {
            selectedDate = d
            Haptics.tap()
        } label: {
            VStack(spacing: 5) {
                Text(weekdayLabel(d))
                    .font(.system(size: 10))
                    .foregroundColor(selected ? Color.white.opacity(0.85) : .secondary)
                Text("\(Calendar.current.component(.day, from: d))")
                    .font(.subheadline.bold())
                    .monospacedDigit()
                    .foregroundColor(selected ? .white : (today ? Theme.brandDeep : .primary))
                Circle()
                    .fill(dotColor(kcal: kcal, selected: selected))
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.solid : (today ? Theme.ink.opacity(0.05) : Color.clear))
            )
        }
        .buttonStyle(.plain)
    }

    private func weekdayLabel(_ d: Date) -> String {
        let idx = Calendar.current.component(.weekday, from: d) - 1
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return names[max(0, min(6, idx))]
    }

    /// 当前正在看的这天用实时合计（刚记完立刻更新），其余天用周汇总
    private func kcalForChip(_ key: String) -> Double? {
        if key == dateStr, state.mealsDate == dateStr {
            return dayTotal.kcal
        }
        return weekSummary[key]?.kcal
    }

    private func dotColor(kcal: Double?, selected: Bool) -> Color {
        if selected { return Color.white.opacity(0.85) }
        guard let k = kcal, k > 0 else { return Color.clear }
        if let target = kcalTarget, target > 0, k > target { return Theme.warning }
        return Theme.brandBlue
    }

    private func loadWeekSummary() async {
        guard let first = weekDates.first, let last = weekDates.last else { return }
        do {
            let items = try await APIClient.shared.fetchMealSummary(
                from: WeightRecord.dateFormatter.string(from: first),
                to: WeightRecord.dateFormatter.string(from: last))
            await MainActor.run {
                var map: [String: APIClient.MealDaySummary] = [:]
                for i in items { map[i.date] = i }
                weekSummary = map
            }
        } catch {
            // 小圆点缺失不影响主流程，静默
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 一周七天一览：点哪天看哪天，箭头按周翻
                weekBar

                // 今日热量预算（没设目标时退回简单合计）
                summaryBar

                Divider()

                if dayMeals.isEmpty {
                    if state.isLoadingMeals && state.mealsDate != dateStr {
                        ProgressView("加载中…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "fork.knife")
                                .font(.system(size: 34, weight: .light))
                                .foregroundColor(Theme.inkTertiary)
                            Text("这一天还没有记录饮食")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(Theme.ink)
                            Text("点下方「拍照记饮食」，拍一张自动识别卡路里")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.inkSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 30)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    List {
                        ForEach(groupedMeals) { group in
                            Section {
                                ForEach(group.items) { m in
                                    mealRow(m)
                                }
                                .onDelete { offsets in
                                    deleteMeals(group.items, at: offsets)
                                }
                            } header: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(typeLabel(group.type))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Theme.inkSecondary)
                                    Spacer()
                                    if group.kcal > 0 {
                                        Text("\(Int(group.kcal.rounded())) 千卡")
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.inkTertiary)
                                            .monospacedDigit()
                                    }
                                }
                                .textCase(nil)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .listRowSeparatorTint(Theme.hairline)
        .background(Theme.canvas)
                    .refreshable { await state.refreshMeals(date: dateStr) }
                }

                // 底部操作栏：拍照识图为主操作
                bottomBar
            }
            .navigationTitle("饮食")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Haptics.tap()
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showSearch) {
                MealSearchView(targetDate: dateStr)
            }
            .sheet(isPresented: $showAdd) {
                MealEditView(dateStr: dateStr)
            }
            .sheet(item: $editingMeal) { m in
                MealEditView(dateStr: m.date, meal: m)
            }
            .sheet(isPresented: $showViewer) {
                if let url = viewingImage {
                    ImageViewer(url: url)
                }
            }
            .sheet(isPresented: $showFoodRecognize) {
                FoodRecognizeView(dateStr: dateStr)
            }
            .sheet(isPresented: $showNutritionOCR) {
                NutritionOCRView(dateStr: dateStr)
            }
            .sheet(isPresented: $showVoice) {
                VoiceRecordView(dateStr: dateStr)
            }
            .sheet(isPresented: $showFrequent) {
                FrequentMealsView(dateStr: dateStr)
            }
            .onChange(of: dateStr) { _ in
                Task { await state.refreshMeals(date: dateStr) }
            }
            .task {
                await state.refreshMeals(date: dateStr)
                // 预热昨天：往回翻一页也瞬间出内容
                if let prev = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) {
                    await state.prefetchMeals(date: WeightRecord.dateFormatter.string(from: prev))
                }
            }
            .task(id: weekKey) {
                await loadWeekSummary()
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 按餐次分组

    private struct MealGroup: Identifiable {
        let id: String
        let type: String
        let items: [MealRecord]
        let kcal: Double
    }

    private var groupedMeals: [MealGroup] {
        let order = ["breakfast", "lunch", "dinner", "snack"]
        return order.compactMap { t in
            let items = dayMeals.filter { $0.type == t }
            guard !items.isEmpty else { return nil }
            return MealGroup(id: t, type: t, items: items,
                             kcal: items.reduce(0.0) { $0 + ($1.kcal ?? 0) })
        }
    }

    private func typeLabel(_ t: String) -> String {
        switch t {
        case "breakfast": return "早餐"
        case "lunch": return "午餐"
        case "dinner": return "晚餐"
        default: return "加餐"
        }
    }

    private func mealRow(_ m: MealRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.content)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.ink)
                    .lineLimit(2)
                if !m.kcalText.isEmpty {
                    Text(m.kcalText)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.brandDeep)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 6)
            if let url = APIClient.shared.imageURL(for: m.image_url) {
                ThumbnailImage(url: url, size: 48)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewingImage = url
                        showViewer = true
                    }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.inkTertiary.opacity(0.7))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { editingMeal = m }
    }

    /// 底部操作栏：拍照识图主按钮 + 两个次要入口
    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button { showFoodRecognize = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera")
                        .font(.system(size: 15, weight: .medium))
                    Text("拍照记饮食")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .background(Theme.brandGradient)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .buttonStyle(PressableStyle())

            HStack(spacing: 10) {
                secondaryButton("常吃", icon: "clock.arrow.circlepath") { showFrequent = true }
                secondaryButton("语音", icon: "mic.fill") { showVoice = true }
                secondaryButton("手动", icon: "square.and.pencil") { showAdd = true }
                secondaryButton("配料表", icon: "text.viewfinder") { showNutritionOCR = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(UIColor.systemBackground))
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.system(size: 11))
            }
            .foregroundColor(Theme.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
        }
    }

    private func shiftWeek(_ weeks: Int) {
        if let nd = Calendar.current.date(byAdding: .day, value: weeks * 7, to: selectedDate) {
            selectedDate = nd
            Haptics.tap()
        }
    }

    private func deleteMeals(_ items: [MealRecord], at offsets: IndexSet) {
        let targets = offsets.map { items[$0] }
        Haptics.tap()
        Task {
            var failed = 0
            for m in targets {
                do { try await APIClient.shared.deleteMeal(id: m.id) }
                catch { failed += 1 }
            }
            await state.refreshMeals(date: dateStr)
            await MainActor.run {
                if failed > 0 { Haptics.error() } else { Haptics.success() }
            }
        }
    }
}

/// 食物图片大图查看
struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationView {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.system(size: 40)).foregroundColor(.secondary)
                        Text("图片加载失败").font(.footnote).foregroundColor(.secondary)
                    }
                default:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(UIColor.systemBackground))
            .navigationTitle("食物照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

/// 饮食录入 / 编辑（传入 meal 则为编辑模式）
struct MealEditView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let dateStr: String
    var meal: MealRecord? = nil   // 编辑模式：传入要编辑的记录

    @State private var type = MealRecord.autoType()
    @State private var content = ""
    @State private var kcalText = ""
    @State private var mealDate = Date()
    @State private var isBusy = false
    @State private var error: String?

    private let types = [("breakfast", "早餐"), ("lunch", "午餐"), ("dinner", "晚餐"), ("snack", "加餐")]
    private var isEditing: Bool { meal != nil }

    var body: some View {
        NavigationView {
            Form {
                Section("餐次") {
                    Picker("餐次", selection: $type) {
                        ForEach(types, id: \.0) { t in Text(t.1).tag(t.0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("日期") {
                    DatePicker("日期", selection: $mealDate, displayedComponents: .date)
                }
                Section("内容") {
                    TextEditor(text: $content)
                        .frame(minHeight: 120)
                }
                Section {
                    HStack {
                        Text("卡路里")
                        TextField("可留空", text: $kcalText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("千卡")
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("AI 估算不准时可以在这里手改；留空表示不计入卡路里统计。")
                }
                if let error {
                    Section { Text(error).foregroundColor(.red) }
                }
            }
            .navigationTitle(isEditing ? "编辑饮食" : "记录饮食")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(isBusy || content.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let m = meal {
                    type = m.type
                    content = m.content
                    if let k = m.kcal, k > 0 {
                        kcalText = String(format: "%.0f", k)
                    }
                }
                mealDate = WeightRecord.dateFormatter.date(from: meal?.date ?? dateStr) ?? Date()
            }
        }
    }

    private func save() {
        let trimmedKcal = kcalText.trimmingCharacters(in: .whitespaces)
        var kcalValue: Double?
        if !trimmedKcal.isEmpty {
            guard let k = Double(trimmedKcal), k >= 0, k <= 5000 else {
                error = "卡路里请输入 0~5000 之间的数字"
                Haptics.warning()
                return
            }
            kcalValue = k
        }

        isBusy = true
        error = nil
        let newDate = WeightRecord.dateFormatter.string(from: mealDate)
        Task {
            if let m = meal {
                do {
                    _ = try await APIClient.shared.updateMeal(id: m.id, date: newDate, type: type,
                                                              content: content, kcal: kcalValue,
                                                              protein_g: m.protein_g, fat_g: m.fat_g,
                                                              carbs_g: m.carbs_g, image_url: m.image_url)
                    await state.refreshMeals(date: newDate)
                    // 改了日期：旧日期缓存作废，并让列表回到原来查看的那天
                    if m.date != newDate {
                        state.invalidateMeals(date: m.date)
                        await state.refreshMeals(date: dateStr)
                    }
                    await MainActor.run {
                        isBusy = false
                        Haptics.success()
                        dismiss()
                    }
                } catch let err {
                    await MainActor.run {
                        isBusy = false
                        Haptics.error()
                        error = err.localizedDescription
                    }
                }
            } else {
                // 新增：断网自动进离线队列，不丢记录
                let outcome = await state.saveMealResilient(date: newDate, type: type, content: content,
                                                            kcal: kcalValue, protein_g: nil, fat_g: nil,
                                                            carbs_g: nil, image_url: nil)
                await MainActor.run {
                    isBusy = false
                    switch outcome {
                    case .synced:
                        Haptics.success()
                        dismiss()
                    case .queued:
                        Haptics.success()
                        state.showToast("已存本地，联网后自动同步")
                        dismiss()
                    case .failed(let msg):
                        Haptics.error()
                        error = msg
                    }
                }
            }
        }
    }
}
