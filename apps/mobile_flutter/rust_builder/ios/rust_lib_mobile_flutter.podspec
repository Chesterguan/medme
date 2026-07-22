#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint rust_lib_mobile_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'rust_lib_mobile_flutter'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter FFI plugin project.'
  s.description      = <<-DESC
A new Flutter FFI plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.script_phase = {
    :name => 'Build Rust library',
    # First argument is relative path to the `rust` folder, second is name of rust library
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../rust rust_lib_mobile_flutter',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    # Let XCode know that the static library referenced in -force_load below is
    # created by this build step.
    :output_files => ["${BUILT_PRODUCTS_DIR}/librust_lib_mobile_flutter.a"],
  }
  # iOS 上本 crate 链接 PP-OCRv5(ort/ONNX Runtime + oar-ocr 的 C++ 传递依赖)。
  #
  # 1) `-lc++` / `-framework CoreML`:ort build script 发的 link-lib=c++ /
  #    framework=CoreML 只在 cargo 自己链接时生效;这里 Rust 编成静态库、Xcode 做
  #    最终链接,cargo 那些指令传不过来,必须显式补上,否则 libc++(std::__1::*)/
  #    CoreML 符号全 undefined。
  #
  # 2) 不能用 cargokit 默认的 `-force_load` 整库加载:pyke 预编译的
  #    libonnxruntime.a 内部含 28 个自相冲突的重复对象(如 onnx-ml.pb.cc.o 出现
  #    两份,彼此各有独有符号)。`-force_load` 会把每个对象都拉进来 → 757 个
  #    duplicate symbol;删任一份 → 又缺符号。普通「按需链接」不会有这个问题
  #    (链接器每个符号取首个定义、忽略后续),所以这里改成让 onnxruntime 按需
  #    链接。
  #    cargokit 之所以要 force_load,是为了防止 Dart 运行时 dlsym 的 FRB 入口符号
  #    被死代码消除。改用 `-u` 把 FRB 运行时那批固定符号钉成链接根即可——
  #    FRB 的单一 dispatcher(frb_pde_ffi_dispatcher_*)静态引用了所有 wire 函数,
  #    保留它就会按需拉入整条闭包(wire → ocr → ort → onnxruntime)。这批 `_frb_*`
  #    是 FRB 运行时固定符号(非按用户函数变化),bridge 重新生成也不变。
  #    本地已验证:0 duplicate、0 undefined,14 个符号全部进 dyld 导出表
  #    (DynamicLibrary.process() 运行时可查到)。
  frb_roots = %w[
    _frb_pde_ffi_dispatcher_primary _frb_pde_ffi_dispatcher_sync
    _frb_init_frb_dart_api_dl _frb_get_rust_content_hash
    _frb_dart_fn_deliver_output _frb_create_shutdown_callback
    _frb_dart_opaque_dart2rust_encode _frb_dart_opaque_rust2dart_decode
    _frb_dart_opaque_drop_thread_box_persistent_handle
    _frb_free_wire_sync_rust2dart_dco _frb_free_wire_sync_rust2dart_sse
    _frb_rust_vec_u8_new _frb_rust_vec_u8_free _frb_rust_vec_u8_resize
  ].map { |sym| "-Wl,-u,#{sym}" }.join(' ')
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Flutter.framework does not contain a i386 slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => "${BUILT_PRODUCTS_DIR}/librust_lib_mobile_flutter.a #{frb_roots} -lc++ -framework CoreML",
  }
end