import SwiftUI
import PhotosUI
import UIKit

/// Attaches every import source presenter (Files, Photos, Camera, Paste) to a view.
/// The flags are owned by the caller (library toolbar / empty state buttons).
struct ImportSourcesModifier: ViewModifier {
    @Binding var showFiles: Bool
    @Binding var showPhotos: Bool
    @Binding var showCamera: Bool
    @Binding var showPaste: Bool

    @Environment(AppModel.self) private var appModel
    @State private var photoItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showFiles,
                allowedContentTypes: ImportTypes.allowed,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task {
                        await appModel.importCoordinator.importFiles(urls)
                    }
                case .failure(let error):
                    appModel.importCoordinator.errorMessage = describeError(error)
                }
            }
            .photosPicker(
                isPresented: $showPhotos,
                selection: $photoItems,
                maxSelectionCount: 20,
                selectionBehavior: .ordered,
                matching: .images
            )
            .onChange(of: photoItems.count) { _, count in
                guard count > 0 else { return }
                let picked = photoItems
                photoItems = []
                Task {
                    await appModel.importCoordinator.importPhotos(picked)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(
                    onImage: { image in
                        showCamera = false
                        Task {
                            await appModel.importCoordinator.importCameraImage(image)
                        }
                    },
                    onCancel: {
                        showCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showPaste) {
                PasteTextSheet()
            }
    }
}

extension View {
    func importSources(
        showFiles: Binding<Bool>,
        showPhotos: Binding<Bool>,
        showCamera: Binding<Bool>,
        showPaste: Binding<Bool>
    ) -> some View {
        modifier(
            ImportSourcesModifier(
                showFiles: showFiles,
                showPhotos: showPhotos,
                showCamera: showCamera,
                showPaste: showPaste
            )
        )
    }
}

/// The "+" import menu contents (shared by the toolbar and the empty state).
struct ImportMenuItems: View {
    @Environment(AppModel.self) private var appModel
    @Binding var showFiles: Bool
    @Binding var showPhotos: Bool
    @Binding var showCamera: Bool
    @Binding var showPaste: Bool

    var body: some View {
        Button {
            showFiles = true
        } label: {
            Label("从文件导入", systemImage: "folder")
        }
        Button {
            showPhotos = true
        } label: {
            Label("从相册选择", systemImage: "photo.on.rectangle")
        }
        Button {
            if CameraPicker.isCameraAvailable {
                showCamera = true
            } else {
                appModel.importCoordinator.errorMessage = "当前设备没有可用的相机（模拟器不支持拍照），请改用“从相册选择”。"
            }
        } label: {
            Label("拍照识谱", systemImage: "camera")
        }
        Button {
            showPaste = true
        } label: {
            Label("粘贴文本", systemImage: "doc.on.clipboard")
        }
    }
}
