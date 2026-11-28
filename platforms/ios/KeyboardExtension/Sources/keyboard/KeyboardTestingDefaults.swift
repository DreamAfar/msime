import Foundation

/// 测试期专用：未签名 IPA 用免费账号重签之后拿不到 App Group，「设置 → 开发者选项 → 诊断日志」写进共享文档的开关传不到键盘扩展，
/// 键盘读到的 `diagnostic_log.server` 永远是关的。这里把验收这次改动必须的项直接置为开，测试包靠它才能留下记录。
///
/// 只在键盘扩展进程里生效（`Bundle.main` 是 `.appex`）：单元测试跑在测试宿主 App 里，`configureDiagnosticLog` 仍按文档里的开关走，
/// `TouchPointTests` 那条「关掉日志就不导出键位几何」才有意义。
///
/// 这个文件和 `configureDiagnosticLog` 里对它的引用都不进上游 PR：开 PR 前整文件删除，把那一处改回
/// `DiagnosticLog.isEnabled(in: preferences)`。
enum KeyboardTestingDefaults {
  /// 诊断日志。启动分段计时（`keyboard_timing`）、主线程卡顿（`main_stall`）、首帧后交互（`first_frame_idle`、`first_key`）、
  /// 常驻内存分项（`canvas=`、`keys=`、`translations=`、`sound=`）都只在它开着时才写得出来。
  static var diagnosticLog: Bool { Bundle.main.bundlePath.hasSuffix(".appex") }
}
