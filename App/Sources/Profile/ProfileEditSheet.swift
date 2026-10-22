import SwiftUI
import PhotosUI
import AGRCore

/// Edit sheet for the own profile. Text fields are applied with "完成"; avatar changes apply immediately.
/// Everything is saved locally first and synced when the server is reachable.
@MainActor
struct ProfileEditSheet: View {
    let store: ProfileStore

    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var bio = ""
    @State private var level: CommunityLevel?
    @State private var genres: [String] = []
    @State private var customGenre = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isProcessingPhoto = false
    @State private var photoError: String?
    @State private var loaded = false

    private let emojiColumns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    private var trimmedNickname: String { ProfileRules.nickname(nickname) }

    var body: some View {
        NavigationStack {
            Form {
                avatarSection
                SwiftUI.Section("昵称") {
                    TextField("昵称（最多 \(CommunityProfile.maxNicknameLength) 字）", text: $nickname)
                        .onChange(of: nickname) {
                            if nickname.count > CommunityProfile.maxNicknameLength {
                                nickname = String(nickname.prefix(CommunityProfile.maxNicknameLength))
                            }
                        }
                }
                SwiftUI.Section {
                    TextEditor(text: $bio)
                        .frame(minHeight: 80)
                        .onChange(of: bio) {
                            if bio.count > CommunityProfile.maxBioLength {
                                bio = String(bio.prefix(CommunityProfile.maxBioLength))
                            }
                        }
                } header: {
                    Text("个人简介")
                } footer: {
                    Text("\(bio.count)/\(CommunityProfile.maxBioLength)")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                SwiftUI.Section("演奏水平") {
                    Picker("演奏水平", selection: $level) {
                        Text("未设置").tag(CommunityLevel?.none)
                        ForEach(CommunityLevel.allCases, id: \.self) { item in
                            Text(item.label).tag(CommunityLevel?.some(item))
                        }
                    }
                    .pickerStyle(.segmented)
                }
                genresSection
                SwiftUI.Section {
                    Text("资料先保存在本机，联网后自动同步到社区服务器。头像与昵称会向其他用户公开。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("编辑资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save() }
                        .disabled(trimmedNickname.isEmpty)
                }
            }
            .onAppear(perform: loadIfNeeded)
            .onChange(of: photoItem) {
                guard let item = photoItem else { return }
                Task { await importPhoto(item) }
            }
        }
    }

    // MARK: Sections

    private var avatarSection: some View {
        SwiftUI.Section("头像") {
            HStack {
                Spacer()
                AvatarView(emoji: store.local.avatarEmoji, imageData: store.avatarData,
                           name: trimmedNickname, size: 88)
                Spacer()
            }
            LazyVGrid(columns: emojiColumns, spacing: 8) {
                ForEach(AvatarEmojis.all, id: \.self) { emoji in
                    Button {
                        store.setAvatarEmoji(emoji)
                    } label: {
                        Text(emoji)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background(
                                store.local.avatarEmoji == emoji ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: Circle()
                            )
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("头像 \(emoji)")
                }
            }
            .padding(.vertical, 4)
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                HStack {
                    Label("从相册选择照片", systemImage: "photo")
                    if isProcessingPhoto {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isProcessingPhoto)
            if store.local.avatarEmoji != nil || store.local.hasAvatarImage {
                Button("移除头像", role: .destructive) {
                    store.setAvatarEmoji(nil)
                }
            }
            if let photoError {
                Text(photoError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var genresSection: some View {
        SwiftUI.Section {
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(genreOptions, id: \.self) { genre in
                    let selected = genres.contains(genre)
                    Button {
                        toggle(genre)
                    } label: {
                        Text(genre)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
            HStack {
                TextField("自定义风格", text: $customGenre)
                    .submitLabel(.done)
                    .onSubmit(addCustomGenre)
                Button("添加", action: addCustomGenre)
                    .buttonStyle(.borderless)
                    .disabled(ProfileRules.genres([customGenre]).isEmpty || genres.count >= CommunityProfile.maxGenres)
            }
        } header: {
            Text("喜欢的风格（最多 \(CommunityProfile.maxGenres) 个）")
        }
    }

    /// Suggestions plus any custom genres already chosen.
    private var genreOptions: [String] {
        GenreSuggestions.all + genres.filter { !GenreSuggestions.all.contains($0) }
    }

    // MARK: Actions

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        nickname = store.local.nickname
        bio = store.local.bio
        level = store.local.level
        genres = store.local.genres
    }

    private func toggle(_ genre: String) {
        if let index = genres.firstIndex(of: genre) {
            genres.remove(at: index)
        } else if genres.count < CommunityProfile.maxGenres {
            genres.append(genre)
        }
    }

    private func addCustomGenre() {
        guard let genre = ProfileRules.genres([customGenre]).first, genres.count < CommunityProfile.maxGenres else { return }
        if !genres.contains(genre) { genres.append(genre) }
        customGenre = ""
    }

    private func save() {
        store.update(LocalProfile.Edit(nickname: trimmedNickname, bio: bio, level: .some(level), genres: genres))
        dismiss()
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        isProcessingPhoto = true
        photoError = nil
        defer {
            isProcessingPhoto = false
            photoItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            photoError = "无法读取所选照片。"
            return
        }
        guard let jpeg = AvatarImageProcessor.squareJPEG(from: data) else {
            photoError = "无法处理这张照片，请换一张。"
            return
        }
        store.setAvatarImage(jpeg: jpeg)
    }
}
