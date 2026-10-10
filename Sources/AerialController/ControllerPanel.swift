import AppKit
import SwiftUI

struct ControllerPanel: View {
    @ObservedObject var model: AppModel
    var onDesktopPlaybackRequested: () -> Void = {}
    private let primaryCategories: [AerialCategory] = [.landscape, .underwater, .cityscape, .earth]

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("航拍控制器").font(.title3.weight(.semibold))
                        Text("Apple 原生航拍 · 单屏").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.isAutomatic ? "轮换中" : "轮换暂停")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(model.isAutomatic ? Color.green.opacity(0.12) : Color.secondary.opacity(0.1), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.currentName).font(.headline).lineLimit(2)
                    Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let next = model.nextDue {
                        Text("下次切换：\(next.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if model.isLoading || model.isSwitching { ProgressView().controlSize(.small) }
                }

                Button {
                    if !model.isAutomatic { onDesktopPlaybackRequested() }
                    model.toggleAutomatic()
                } label: {
                    Label(model.isAutomatic ? "暂停轮换" : "开始轮换",
                          systemImage: model.isAutomatic ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isAutomatic && !model.canSwitch || model.isSwitching)

                HStack(spacing: 8) {
                    Button {
                        onDesktopPlaybackRequested()
                        Task { await model.previous() }
                    } label: {
                        Label("上一张", systemImage: "backward.end.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canPrevious)
                    .help("按本次运行的切换历史回退，并从头完整播放")
                    Button {
                        if model.isPlaybackPaused {
                            onDesktopPlaybackRequested()
                            Task { await model.resumePlayback() }
                        } else {
                            model.pausePlayback()
                        }
                    } label: {
                        Label(model.isPlaybackPaused ? "继续播放" : "暂停播放",
                              systemImage: model.isPlaybackPaused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canPausePlayback && !model.canResumePlayback)
                    .help("暂停保留当前画面；继续从原进度播放，不重头开始")
                    Button {
                        onDesktopPlaybackRequested()
                        Task { await model.next() }
                    } label: {
                        Label("下一张", systemImage: "forward.end.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canSwitch)
                    .help("随机切换下一张，完整播放后停在最后一帧")
                }

                HStack(spacing: 10) {
                    Button {
                        onDesktopPlaybackRequested()
                        Task { await model.replay() }
                    } label: {
                        Label(model.isReplaying && !model.isPlaybackPaused ? "播放中…" : "重新播放", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!model.canReplay)
                    .help("从头完整播放当前航拍，结束后停在最后一帧")
                    if model.hasReplayFrame || model.isReplaying {
                        Button("返回原生画面") { model.stopReplay() }
                    }
                }

                if model.isPlaybackPaused {
                    Text("播放暂停期间跳过自动切换；可继续播放，或手动切换上一张／下一张。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox {
                    VStack(spacing: 10) {
                        ForEach(primaryCategories, id: \.rawValue) { category in
                            HStack {
                                Toggle(category.displayName, isOn: Binding(
                                    get: { model.selectedCategories.contains(category) },
                                    set: { model.setCategory(category, selected: $0) }
                                )).toggleStyle(.checkbox)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(model.downloadedCount(category)) 可轮换 / \(model.localAssetCount(category)) 已下载")
                                    Text(model.storageLabel(category))
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        HStack {
                            Text("可用播放池").font(.caption)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(model.playlist.count) 个已下载航拍")
                                Text(model.playlistStorageLabel)
                            }.font(.caption.weight(.medium))
                        }
                        HStack {
                            Text("全部已索引视频").font(.caption)
                            Spacer()
                            Text(model.storageLabel()).font(.caption.weight(.medium))
                        }
                        Text("按本地文件大小统计，不含缓存、下载临时文件和同一资源的额外副本。取消分类不会删除视频；下载后点击刷新资源更新。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(6)
                } label: { Text("分类组合").font(.caption.weight(.semibold)) }
                .disabled(model.isLoading || model.isSwitching)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("切换间隔", selection: Binding(
                            get: { model.intervalChoice }, set: { model.chooseInterval($0) }
                        )) {
                            Text("15 分钟").tag(15)
                            Text("30 分钟").tag(30)
                            Text("1 小时").tag(60)
                            Text("2 小时").tag(120)
                            Text("自定义分钟").tag(0)
                        }
                        if model.intervalChoice == 0 {
                            HStack {
                                TextField("正整数分钟", text: $model.customMinutes)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { model.applyCustomInterval() }
                                    .accessibilityLabel("自定义分钟数")
                                Button("应用") { model.applyCustomInterval() }
                            }
                        }
                        Text("睡眠漏期跳过，唤醒后重新计时。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("轮换状态会保存，下次打开时继续；手动暂停后保持暂停。登录时自动打开请在系统设置中配置。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(6)
                }.disabled(model.isSwitching)

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("刷新资源") { Task { await model.refresh() } }
                        .disabled(model.isLoading || model.isSwitching || model.isReplaying)
                    Spacer()
                    Button("恢复接管前设置") { Task { await model.restore() } }
                        .disabled(!model.canRestore || model.isSwitching || model.isLoading)
                }.controlSize(.small)

                if model.externalChangeDetected {
                    Button("重新接管当前设置") { Task { await model.adoptCurrentSettings() } }
                        .disabled(model.isLoading || model.isSwitching)
                }

                Divider()
                HStack {
                    Text("向下滚动查看全部控件。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("退出") { NSApplication.shared.terminate(nil) }
                        .disabled(model.isSwitching)
                }.controlSize(.small)
            }.padding(20)
        }
        .frame(width: 360, height: 650)
    }
}
