# Launcher-Re.Download_PATCH

支持的启动器：

- PCL（正式版、快照版）
- PCL-CE
- HMCL

## 使用

1. 下载 [Releases](https://github.com/Jelly10086/PCL-Re.Download_PATCH/releases/latest) 中的 ZIP，完整解压。
2. 关闭启动器，把 EXE 或 JAR 拖到 `启动器下载恢复补丁.bat` 上。也可双击后选择文件。
3. 提示修补完成后，照常启动原文件。

恢复时，把同一文件拖到 `Restore-Original.bat` 上。保留旁边的 `.download-original.bak` 和 `.download-patch.json`。

## 原理

按方法签名和限制代码识别，不按版本号或整个文件的哈希筛选。PCL 回填被裁剪的下载方法，PCL-CE 和 HMCL 关闭对应的下载限制判断。无法匹配的方法不修改；这不代表所有历史及未来构建都能修补。修补过程不改系统地区、时区或代理。[构建与验证](source/BUILD.txt)。

采用 [PolyForm Noncommercial 1.0.0](LICENSE)，禁止倒卖及其他商业用途，二次分发须保留 [NOTICE](NOTICE) 中的作者署名和方案来源。Mono.Cecil 使用其 [MIT 许可证](lib/Mono.Cecil.LICENSE.txt)，PCL 回填数据受[上游许可](UPSTREAM-LICENCE.txt)约束。

## 免责声明

第三方补丁，与各启动器官方无关。按现状提供，不保证兼容性或可用性，使用前请备份。
