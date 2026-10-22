import SwiftUI

/// 饮食记录页（按日期分组，可切换日期、增删）
struct MealListView: View {
    @EnvironmentObject var state: AppState

    @State private var selectedDate = Date()
    @State private var showAdd = false
    @State private var showFoodRecognize = false
    @State private var showNutritionOCR = false
    @State private var editingMeal: MealRecord?

    private var dateStr: String { WeightRecord.dateFormatter.string(from: selectedDate) }
    private var dayMeals: [MealRecord] {
        state.meals.filter { $0.date == dateStr }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 日期切换器
                HStack {
                    Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                        .frame(width: 44, height: 44)
                    Spacer()
                    DatePicker("", selection: $selectedDate, displayedComponents: .date)
                        .labelsHidden()
                    Spacer()
                    Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                        .frame(width: 44, height: 44)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                if dayMeals.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("今天还没记录饮食")
                            .font(.headline)
                        Text("点击右下角 + 记一餐")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(dayMeals) { m in
                            HStack(alignment: .top, spacing: 12) {
                                Text(m.typeName)
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(typeColor(m.type))
                                    .cornerRadius(8)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(m.content)
                                        .font(.body)
                                    if !m.kcalText.isEmpty {
                                        Text(m.kcalText)
                                            .font(.caption)
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { editingMeal = m }
                        }
                        .onDelete(perform: deleteItems)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("饮食")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("手动记录", systemImage: "square.and.pencil") }
                        Button { showFoodRecognize = true } label: { Label("拍照识图", systemImage: "camera") }
                        Button { showNutritionOCR = true } label: { Label("拍配料表", systemImage: "text.viewfinder") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                MealEditView(dateStr: dateStr)
            }
            .sheet(item: $editingMeal) { m in
                MealEditView(dateStr: m.date, meal: m)
            }
            .sheet(isPresented: $showFoodRecognize) {
                FoodRecognizeView(dateStr: dateStr)
            }
            .sheet(isPresented: $showNutritionOCR) {
                NutritionOCRView(dateStr: dateStr)
            }
            .onChange(of: dateStr) { _ in
                Task { await state.refreshMeals(date: dateStr) }
            }
            .task { await state.refreshMeals(date: dateStr) }
        }
        .navigationViewStyle(.stack)
    }

    private func typeColor(_ t: String) -> Color {
        switch t {
        case "breakfast": return .orange
        case "lunch": return .green
        case "dinner": return .purple
        default: return .gray
        }
    }

    private func shiftDay(_ d: Int) {
        if let nd = Calendar.current.date(byAdding: .day, value: d, to: selectedDate) {
            selectedDate = nd
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let items = offsets.map { dayMeals[$0] }
        Task {
            for m in items {
                try? await APIClient.shared.deleteMeal(id: m.id)
            }
            await state.refreshMeals(date: dateStr)
        }
    }
}

/// 饮食录入 / 编辑（传入 meal 则为编辑模式）
struct MealEditView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let dateStr: String
    var meal: MealRecord? = nil   // 编辑模式：传入要编辑的记录

    @State private var type = "breakfast"
    @State private var content = ""
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
                Section("内容") {
                    TextEditor(text: $content)
                        .frame(minHeight: 120)
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
                }
            }
        }
    }

    private func save() {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                if let m = meal {
                    _ = try await APIClient.shared.updateMeal(id: m.id, date: m.date, type: type,
                                                              content: content, kcal: m.kcal,
                                                              protein_g: m.protein_g, fat_g: m.fat_g,
                                                              carbs_g: m.carbs_g, image_url: m.image_url)
                } else {
                    _ = try await APIClient.shared.saveMeal(date: dateStr, type: type, content: content)
                }
                await state.refreshMeals(date: meal?.date ?? dateStr)
                await MainActor.run { dismiss() }
            } catch let err {
                await MainActor.run { error = err.localizedDescription }
            }
        }
    }
}
