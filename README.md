# DisplayVolume

[简体中文](#简体中文) · [English](#english)

## 简体中文

DisplayVolume 是一个适用于 Apple Silicon Mac 的后台工具。把未来视野 RV200 Ultra 选为声音输出后，可以用键盘上的音量加、减和静音键，通过 DDC/CI 调节显示器的硬件音量。调节时，显示器右上角会短暂出现音量浮层。

### 功能

- 短按音量键调一档，长按连续调节，松开即停。
- 音量分为 16 档，采用指数曲线。低音量区的步距较小，高音量区逐渐拉开。0 档为静音。
- 浮层显示当前档位，音量条会滑动填充或收回。减到 0 时，扬声器图标过渡到静音状态。
- 安装后可随 macOS 登录启动。切换到其他声音输出、锁屏或退出时，程序释放它安装的键盘映射。

显示器报告的硬件范围为 0–100 时，第 4、8、12、16 档分别写入 4、10、32、100。浮层显示的是档位。实际响度由显示器的音量响应决定。

### 兼容性

| 项目 | 支持范围 |
| --- | --- |
| 处理器 | Apple Silicon |
| 系统 | 部署目标为 macOS 13 或更新版本 |
| 构建工具 | 带 macOS 26 SDK 或更新 SDK 的 Xcode 或 Command Line Tools |
| 显示器 | 当前识别 RV200 Ultra，要求它是唯一匹配的在线显示器，并选为当前声音输出 |
| 实测环境 | M5 MacBook Air、macOS 27.3、RV200 Ultra，音频传输类型为 DisplayPort |

macOS 26 及以上版本使用 AppKit 的透明 Liquid Glass 材质。较早版本使用 AppKit 的半透明浮层材质。DDC 传输依赖 macOS 的私有 `IOAVService` 接口，兼容性取决于 macOS 版本、显示器固件和连接方式。

### 安装与更新

用当前登录的 macOS 用户在终端运行以下命令。该用户需要能写入 `/Applications`。

```sh
git clone https://github.com/Waylon524/DisplayVolume.git
cd DisplayVolume
./script/build_and_run.sh --install
```

脚本会构建并本地签名应用，将它安装到 `/Applications/DisplayVolume.app`，启动后台进程并注册登录项。安装后，在「系统设置 → 声音 → 输出」选择 **RV200 Ultra**。若同时运行 BetterDisplay、MonitorControl 或其他处理媒体键的工具，先退出相应工具，再测试 DisplayVolume。

从同一份工作目录更新时，拉取最新版并再次运行安装脚本。

```sh
git pull --ff-only
./script/build_and_run.sh --install
```

### 构建与诊断

```sh
# 只构建本地应用包
./script/build_and_run.sh --build

# 构建并从临时目录启动应用
./script/build_and_run.sh

# 读取当前 RV200 Ultra 的硬件音量
/Applications/DisplayVolume.app/Contents/MacOS/DisplayVolume --probe

# 查看登录项状态
/Applications/DisplayVolume.app/Contents/MacOS/DisplayVolume --login-status

# 查看运行日志
/usr/bin/log stream --style compact --predicate 'subsystem == "io.waylon.display-volume"'
```

| 现象 | 检查方法 |
| --- | --- |
| macOS 的输出音量滑块呈灰色 | DisplayPort 输出的系统音量控件可能不可用。用键盘音量键调节并观察 DisplayVolume 浮层，或用 `--probe` 读取硬件音量。 |
| `--probe` 无法读取音量 | 确认 RV200 Ultra 已连接并选为当前声音输出。再检查连接链路是否支持 DDC/CI。 |
| 探测成功，按键无反应 | 确认按下的是媒体音量键，并检查是否有其他应用处理相同按键。DisplayVolume 将音量键映射到 F16、F17、F18，遇到已有冲突映射时会跳过对应键盘服务。 |
| 登录后未启动 | 在「系统设置 → 通用 → 登录项与扩展」查看 DisplayVolume，或运行 `--login-status` 确认状态。 |

### 停止与卸载

在项目目录中运行以下命令，再将 `/Applications/DisplayVolume.app` 移到废纸篓。也可以在「系统设置 → 通用 → 登录项与扩展」停用登录项。

```sh
/Applications/DisplayVolume.app/Contents/MacOS/DisplayVolume --disable-login
./script/build_and_run.sh --stop
```

### 项目结构

| 文件 | 职责 |
| --- | --- |
| `Sources/main.m` | 音量键、长按、档位曲线、声音输出检测和登录项 |
| `Sources/Monitor.m` | 显示器识别和 DDC/CI 硬件音量读写 |
| `Sources/VolumeHUD.m` | 音量浮层、声波、静音和填充动画 |
| `script/build_and_run.sh` | 构建、签名、安装和运行 |

### 许可证

项目使用 [MIT 许可证](LICENSE)。DDC/CI 传输参考了 [m1ddc](https://github.com/waydabber/m1ddc)，其 MIT 许可与版权声明见 [ThirdPartyNotices.txt](ThirdPartyNotices.txt)。

---

## English

DisplayVolume is a background utility for Apple silicon Macs. When the RICH VISION RV200 Ultra is selected as the sound output, the keyboard’s volume up, volume down, and mute keys adjust the monitor’s hardware volume over DDC/CI. A brief on-screen display appears in the monitor’s upper-right corner.

### Features

- Tap to move one step. Hold to repeat and release to stop.
- Use a 16-step exponential volume curve with finer changes at quiet levels and wider changes toward the top. Step zero is mute.
- See the active step in the on-screen display. The fill slides as volume changes, and the speaker icon animates into its muted state at zero.
- Start at macOS login after installation. The utility releases its key mappings when the audio output changes, the session locks, or the app exits.

On a display reporting a hardware range of 0–100, steps 4, 8, 12, and 16 write values of 4, 10, 32, and 100. The on-screen display shows the step. Audible loudness depends on the monitor’s own volume response.

### Compatibility

| Item | Support |
| --- | --- |
| Processor | Apple silicon |
| Operating system | Deployment target of macOS 13 or later |
| Build tools | Xcode or Command Line Tools with the macOS 26 SDK or later |
| Monitor | The RV200 Ultra must be the single matching online display and the selected sound output |
| Tested setup | M5 MacBook Air, macOS 27.3, and RV200 Ultra with DisplayPort audio |

The overlay uses AppKit’s clear Liquid Glass material on macOS 26 and later and a translucent AppKit material on earlier versions. DDC transport uses macOS’s private `IOAVService` interface, so compatibility depends on the macOS version, monitor firmware, and connection.

### Install and update

Run these commands in Terminal as the signed-in macOS user. The account needs write access to `/Applications`.

```sh
git clone https://github.com/Waylon524/DisplayVolume.git
cd DisplayVolume
./script/build_and_run.sh --install
```

The script builds and locally signs the app, installs it at `/Applications/DisplayVolume.app`, starts the background process, and registers the login item. In **System Settings → Sound → Output**, select **RV200 Ultra**. Quit BetterDisplay, MonitorControl, or any other utility handling the same media keys before testing DisplayVolume.

To update an existing checkout, pull the latest changes and run the installer again.

```sh
git pull --ff-only
./script/build_and_run.sh --install
```

### Build and diagnose

```sh
# Build the local app bundle
./script/build_and_run.sh --build

# Build and launch from the temporary directory
./script/build_and_run.sh

# Read the current RV200 Ultra hardware volume
/Applications/DisplayVolume.app/Contents/MacOS/DisplayVolume --probe

# Check the login item status
/Applications/DisplayVolume.app/Contents/MacOS/DisplayVolume --login-status

# View runtime logs
/usr/bin/log stream --style compact --predicate 'subsystem == "io.waylon.display-volume"'
```

| Symptom | What to check |
| --- | --- |
| The macOS output slider is dimmed | The system volume control can be unavailable for DisplayPort audio. Use the media keys and look for the DisplayVolume overlay, or read the hardware level with `--probe`. |
| `--probe` cannot read the volume | Confirm that the RV200 Ultra is connected and selected as the sound output. Check that the connection supports DDC/CI. |
| The probe succeeds, and the keys have no effect | Confirm that the keyboard sends media volume controls. Check whether another app handles the same keys. DisplayVolume maps the controls to F16, F17, and F18 and skips keyboard services with conflicting mappings. |
| The app did not start at login | Check **System Settings → General → Login Items & Extensions**, or run `--login-status`. |

### Stop or uninstall

From the project directory, run the commands below and move `/Applications/DisplayVolume.app` to the Trash. You can also disable startup in **System Settings → General → Login Items & Extensions**.

```sh
/Applications/DisplayVolume.app/Contents/MacOS/DisplayVolume --disable-login
./script/build_and_run.sh --stop
```

### Project layout

| File | Purpose |
| --- | --- |
| `Sources/main.m` | Media keys, key repeat, volume curve, sound output detection, and the login item |
| `Sources/Monitor.m` | Display identification and DDC/CI hardware volume reads and writes |
| `Sources/VolumeHUD.m` | On-screen display, speaker waves, mute transition, and fill animation |
| `script/build_and_run.sh` | Build, signing, installation, and launch |

### License

DisplayVolume is distributed under the [MIT License](LICENSE). Its DDC/CI transport is based on [m1ddc](https://github.com/waydabber/m1ddc). See [ThirdPartyNotices.txt](ThirdPartyNotices.txt) for the upstream MIT license and copyright notice.
