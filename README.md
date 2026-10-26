# Launcher-Re.Download_PATCH

支持的启动器：

- PCL（正式版、快照版）
- PCL-CE
- HMCL

## 使用

1. 下载 [Releases](https://github.com/Jelly10086/PCL-Re.Download_PATCH/releases/latest) 中的 ZIP，完整解压。
2. 关闭启动器，把 EXE 或 JAR 拖到 `Launcher-Re.Download_PATCH.bat` 上。也可双击后选择文件。
3. 提示修补完成后，照常启动原文件。

恢复时，把同一文件拖到 `Restore-Original.bat` 上。保留旁边的 `.download-original.bak` 和 `.download-patch.json`。

旧补丁出现原版游戏下载页空引用时，保留这两个文件，再拖入启动器即可重新修补。

## 原理

按方法签名和限制代码识别，不按版本号或整个文件的哈希筛选。PCL 忽略限制提示文案及等价 IL 编码差异，回填下载方法并恢复被隐藏的原版下载、整合包导入入口；PCL-CE 和 HMCL 关闭对应的下载限制判断。业务结构无法匹配时不修改，不保证任意未来版本都兼容。修补过程不改系统地区、时区或代理。[构建与验证](source/BUILD.txt)。

采用 [PolyForm Noncommercial 1.0.0](LICENSE)，禁止倒卖及其他商业用途，二次分发须保留 [NOTICE](NOTICE) 中的作者署名和方案来源。Mono.Cecil 使用其 [MIT 许可证](lib/Mono.Cecil.LICENSE.txt)，PCL 回填数据受[上游许可](UPSTREAM-LICENCE.txt)约束。

## 免责声明

第三方补丁，与各启动器官方无关。按现状提供，不保证兼容性或可用性，使用前请备份。
