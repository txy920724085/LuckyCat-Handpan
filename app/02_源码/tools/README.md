# tools 目录说明

为控制提交体积，这里不包含 60MB+ 的 Android 工具链。请按《构建说明.md》下载并放入：

```
tools/
├── android-14/         # build-tools r34（aapt2.exe、zipalign.exe、apksigner.bat、lib/apksigner.jar 等）
├── android-35/
│   └── android.jar
└── r8.jar              # R8 9.5.28
```

确认可用：

```bat
tools\android-14\aapt2.exe version
java -cp tools\r8.jar com.android.tools.r8.D8 --version
```

也可以设置 `HP_TOOLS` 指向任意位置的 tools：

```bat
set HP_TOOLS=D:\android-tools
build.bat
```
