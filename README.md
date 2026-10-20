# PCL-Re.Download_PATCH

恢复官方 PCL 2.99.0.0 的 MC 下载功能。支持正式版和快照版。

## 使用

1. 下载 [Releases](https://github.com/Jelly10086/PCL-Re.Download_PATCH/releases/latest) 中的 ZIP 并解压。
2. 关闭 PCL，把原版 EXE 拖到 `Apply-Patch.bat` 上。
3. 提示完成后，启动该 EXE。

没有原版时，双击 `Apply-Patch.bat`，自动下载（正式版）并生成修补版。
恢复时，把同一个 EXE 拖到 `Restore-Original.bat` 上，保留 `.pcl-original.bak` 备份。

采用 [PolyForm Noncommercial 1.0.0](LICENSE)。禁止倒卖及其他商业用途，二次分发须保留 [NOTICE](NOTICE) 中的作者署名和方案来源。

## 原理

用限制提交前的官方实现恢复下载相关方法，保留其余功能和内嵌资源。修补前后均校验 SHA256，仅支持对应的官方 2.99.0.0。构建说明见 [source/BUILD.txt](source/BUILD.txt)。

## 免责声明

这是第三方补丁，与 PCL 官方无关。PCL 原作者为龙腾猫跃，相关内容仍受[上游许可](UPSTREAM-LICENCE.txt)约束。本补丁按现状提供，不保证兼容性或可用性；使用前请备份，风险由使用者承担。