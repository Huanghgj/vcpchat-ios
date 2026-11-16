#if os(iOS)
import SwiftUI
import VChatCore

struct AdvancedReplySettingsView: View {
    let model: ChatViewModel
    @State private var draft: AdvancedReplyConfiguration
    @State private var editing: AdvancedReplyRule?
    @State private var saving = false
    @State private var editMode: EditMode = .inactive

    init(model: ChatViewModel) {
        self.model = model
        _draft = State(initialValue: model.advancedReplies)
    }

    var body: some View {
        List {
            Section {
                Button { editing = AdvancedReplyRule() } label: {
                    Label("新建注入规则",systemImage: "plus")
                }
                NavigationLink {
                    ReplyOwnerList(agents: model.agents,groups: model.groups,draft: $draft)
                } label: {
                    Label("Agent／群组覆盖",systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("规则只进入发给模型的请求。保存后生效，不修改旧消息或渲染设置。")
            }

            Section {
                ForEach(draft.rules) { rule in
                    HStack(spacing: 12) {
                        Button { editing = rule } label: {
                            VStack(alignment: .leading,spacing: 4) {
                                Text(rule.name).foregroundStyle(.primary)
                                Text([rule.isBuiltin ? "预置" : "自定义",rule.type.title,rule.scope.title].joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Toggle("启用 \(rule.name)",isOn: enabled(rule.id)).labelsHidden()
                    }
                    .contextMenu {
                        if let index = draft.rules.firstIndex(where: { $0.id == rule.id }) {
                            Button("上移",systemImage: "arrow.up") { draft.rules.move(fromOffsets: IndexSet(integer: index),toOffset: index - 1) }.disabled(index == 0)
                            Button("下移",systemImage: "arrow.down") { draft.rules.move(fromOffsets: IndexSet(integer: index),toOffset: index + 2) }.disabled(index == draft.rules.count - 1)
                        }
                        if !rule.isBuiltin {
                            Button("删除",systemImage: "trash",role: .destructive) { draft.removeRule(id: rule.id) }
                        }
                    }
                }.onMove { from,to in draft.rules.move(fromOffsets: from,toOffset: to) }
            } header: {
                Text("全局规则")
            } footer: {
                Text("同一位置按列表顺序注入；历史规则先按深度安排，同深度再按列表顺序。工具预置只提示用法，不替代服务器或工具节点授权。")
            }
        }
        .environment(\.editMode,$editMode)
        .disabled(saving)
        .navigationTitle("高级回复")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "完成排序" : "排序") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                Button("保存") { save() }.disabled(saving || draft == model.advancedReplies)
            }
        }
        .sheet(item: $editing) { rule in
            ReplyRuleEditor(rule: rule) { updated in
                if let index = draft.rules.firstIndex(where: { $0.id == updated.id }) { draft.rules[index] = updated }
                else { draft.rules.append(updated) }
            }
        }
    }

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(get: { draft.rules.first { $0.id == id }?.enabled ?? false },set: { value in
            if let index = draft.rules.firstIndex(where: { $0.id == id }) { draft.rules[index].enabled = value }
        })
    }
    private func save() {
        let value = draft
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do { try await model.saveAdvancedReplies(value) }
            catch { model.error = error.localizedDescription }
        }
    }
}
private struct ReplyRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: AdvancedReplyRule
    var onSave: (AdvancedReplyRule) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("规则") {
                    TextField("规则名称",text: $rule.name)
                    Toggle("全局启用",isOn: $rule.enabled)
                    Picker("作用范围",selection: $rule.scope) {
                        ForEach(ReplyRuleScope.allCases,id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    Picker("注入位置",selection: $rule.type) {
                        ForEach(ReplyInjectionPosition.allCases,id: \.self) { Text($0.title).tag($0) }
                    }
                    if rule.type == .context {
                        Picker("注入角色",selection: Binding(get: { rule.role ?? .user },set: { rule.role = $0 })) {
                            ForEach(ReplyInjectionRole.allCases,id: \.self) { Text($0.title).tag($0) }
                        }
                        TextField("深度",value: Binding(get: { rule.depth ?? 0 },set: { rule.depth = $0 }),format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                        Text("0 放在最后；1 放在最后一条之前。按消息计数，不计系统提示词。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("标明由客户端注入",isOn: $rule.wrap)
                } header: { Text("请求位置") }
                Section("提示词") {
                    TextEditor(text: $rule.content).font(.body.monospaced()).frame(minHeight: 180)
                        .accessibilityLabel("提示词内容")
                }
            }
            .navigationTitle(rule.isBuiltin ? "编辑预置规则" : "编辑规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if rule.type == .context { rule.depth = max(0,rule.depth ?? 0); rule.role = rule.role ?? .user }
                        else { rule.role = nil; rule.depth = nil }
                        onSave(rule); dismiss()
                    }.disabled(rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                               rule.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                               (rule.type == .context && (rule.depth ?? 0) < 0))
                }
            }
        }.frame(minWidth: 340,minHeight: 490)
    }
}
private struct ReplyOwnerList: View {
    var agents: [VCPAgent]
    var groups: [VCPGroup]
    @Binding var draft: AdvancedReplyConfiguration
    var body: some View {
        List {
            if !agents.isEmpty {
                Section("Agent") {
                    ForEach(agents) { agent in item(agent.name,owner: ReplyRuleOwner(.agent,id: agent.id)) }
                }
            }
            if !groups.isEmpty {
                Section("群组") {
                    ForEach(groups) { group in item(group.name,owner: ReplyRuleOwner(.group,id: group.id)) }
                }
            }
            if agents.isEmpty && groups.isEmpty { Text("创建 Agent 或群组后，可在这里设置覆盖。").foregroundStyle(.secondary) }
        }.workspaceDetailNavigation().navigationTitle("Agent／群组覆盖")
    }
    private func item(_ title: String,owner: ReplyRuleOwner) -> some View {
        NavigationLink {
            ReplyOwnerOverrides(title: title,owner: owner,draft: $draft)
        } label: {
            HStack {
                Text(title)
                Spacer()
                let count = draft.overrideCount(for: owner)
                Text(count == 0 ? "沿用全局" : "\(count) 条覆盖").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
private struct ReplyOwnerOverrides: View {
    enum Choice: String, CaseIterable, Hashable {
        case inherited, enabled, disabled
        var title: String {
            switch self { case .inherited: "沿用全局"; case .enabled: "强制开启"; case .disabled: "强制关闭" }
        }
    }

    var title: String
    var owner: ReplyRuleOwner
    @Binding var draft: AdvancedReplyConfiguration

    var body: some View {
        List {
            Section {
                ForEach(draft.rules.filter { $0.applies(to: owner) }) { rule in
                    Picker(selection: selection(rule.id)) {
                        ForEach(Choice.allCases,id: \.self) { choice in
                            Text(choice == .inherited ? "沿用全局（\(rule.enabled ? "开" : "关")）" : choice.title).tag(choice)
                        }
                    } label: {
                        VStack(alignment: .leading,spacing: 4) {
                            Text(rule.name)
                            Text(rule.type.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }.pickerStyle(.menu)
                }
            } footer: { Text("返回「高级回复」并保存；覆盖只改变此对象的启停。") }
        }.workspaceDetailNavigation().navigationTitle(title)
    }
    private func selection(_ id: String) -> Binding<Choice> {
        Binding(get: {
            switch draft.override(for: id,owner: owner) { case true?: .enabled; case false?: .disabled; case nil: .inherited }
        },set: { choice in draft.setOverride(choice == .inherited ? nil : choice == .enabled,for: id,owner: owner) })
    }
}
#endif
