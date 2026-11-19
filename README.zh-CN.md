<p align="center">
  <a href="README.md">English</a> | 简体中文
</p>

<p align="center">
  <img src="banner.png" alt="Zerk Play" width="840">
</p>

<p align="center">
  一个免费开源的 Emby / Jellyfin 客户端，支持 <b>Windows</b>、<b>Linux</b> 和 <b>Android TV / Google TV</b>，<br>
  围绕「发现好片」和 Seerr 求片打造。
</p>

<p align="center">
  <a href="https://ko-fi.com/florinp93"><img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Support on Ko-fi"></a>
  &nbsp;
  <a href="https://discord.gg/rBRpMbAVz9"><img src="https://img.shields.io/badge/Discord-%235865F2.svg?style=for-the-badge&logo=discord&logoColor=white" alt="Discord"></a>
</p>

<p align="center">
  <a href="https://github.com/florinp93/Zerk-Play-2.0/releases"><b>下载最新版本</b></a>（Windows / Linux / Android TV）
</p>

![Home](screenshots/01-home-hero.png)

Zerk Play 2 是一次彻底重写，目前仍处于 beta 阶段，难免有粗糙的地方，遇到问题请反馈。已安装的版本会在新版本发布时自动更新。

打开它，它应该帮你找到想看的东西，而不是让你在海报墙里无尽滑动。如果服务器上还没有你想看的片，在同一屏就能直接发起求片。

## 发现优先

首页基于你的观看记录构建，而不只是「最新添加」：

- **看过…的你可能会喜欢** 基于你真正看完的内容推荐
- **现在想看什么？** 按主题分类的片单行，如 *青春成长*、*绝境求生*、*侦探推理*、*劫案与骗局*，每行都标出你库里已有多少部
- **为你挑选**，以及基于你口味的推荐行（*因为你喜欢动作 · 喜剧*）
- **Top 10 热门**，像流媒体平台那样用大数字排行的呈现方式

![Because you watched](screenshots/02-because-you-watched-request.png)

![What are you in the mood for?](screenshots/03-mood-rows.png)

![Top 10 trending](screenshots/04-top10-trending.png)

每部影片都有 **标签**（来自 TMDB 关键词：*劫案*、*杀手*、*真实事件改编*…）。打开一个标签就能看到所有匹配的影片，优先展示你库里已有的。每个详情页还有 **更多类似**，浏览详情时预告片会在背景播放。

![Title details with trailer](screenshots/08-title-details-trailer.png)

![Tags and More like this](screenshots/09-tags-more-like-this.png)

![Tag page](screenshots/10-tag-page.png)

还有 **发现** 页（热门、流行、即将上线）、新片 **日历**，以及基于 TMDB 生成的 **合集**——就算你的服务器没有建合集也能用。

![Discover](screenshots/13-discover.png)

## 求片内置（Seerr）

连接 Seerr 后，库里没有的影片会直接出现在已有影片旁边：

- 每个页面（首页、发现、搜索、更多类似）里，不在库中的影片都会带 **求片** 角标
- 独立的 **求片** 页面：选季、看预告、搞定
- **搜索** 优先展示你的媒体库，然后是可求片的「不在你的媒体库中」一行
- **已求片** 和 **等待上线** 角标，随时掌握哪些片在路上

![Not in your library](screenshots/05-not-in-library-request.png)

![Request page](screenshots/11-request-page.png)

![Search with requests](screenshots/16-search-request-not-in-library.png)

![Coming soon](screenshots/14-coming-soon-requested.png)

## 播放

- **Windows:** mpv（libmpv，D3D11 上的 gpu-next），支持真正的 **HDR** 输出。播放 HDR 视频时可以自动打开 Windows HDR，播完自动关掉。支持音频直通到功放（TrueHD、DTS-HD MA、EAC3…）。
- **Linux:** 同样通过 libmpv 使用 mpv，支持 VA-API（Intel / AMD）或 NVDEC（NVIDIA）硬件解码，Wayland 和 X11 都可用。
- **Android TV:** 原生 Media3 播放器，内置 FFmpeg 音频解码器，并为电视 / 回音壁 / 功放提供直通设置。
- **版本选择:** 一部电影有多个文件时（1080p、2160p 杜比视界…），可以选一个版本，应用会记住你的选择。
- **跳过片头**，手动或自动均可。
- **字幕:** *智能* 模式（优先你的语言，外文对白自动挂强制字幕），字号和样式可调，支持延迟校正。
- TMDB 元数据 **使用你的语言**（标题、简介、Logo、海报），完全不用改动服务器上的媒体库。

![Settings](screenshots/19-settings-content-trailers.png)

## 直播电视

添加你自己的 Xtream Codes IPTV 账号，即可获得完整的 **电视指南**：频道分组、EPG 时间轴和正在播出的节目。直播电视与电影库在同一个应用里并存。

![Live TV guide](screenshots/17-live-tv-guide.png)

## 为遥控器而生

整个界面以 **D-pad / 遥控器 / 键盘** 为第一优先。在 Windows 和 Linux 上同样好用：接个手柄或直接用方向键，鼠标光标会自动隐藏直到你再次移动它。鼠标在任何地方依然可用，支持悬停和滚轮。

电视上配置毫无痛苦：**用手机扫二维码**，在手机上填服务器、TMDB Key 和 Seerr 信息，不用拿遥控器一个字一个字敲。

![Library](screenshots/20-library-movies.png)

## 快速开始

1. 打开[最新发布页](https://github.com/florinp93/Zerk-Play-2.0/releases)（最新版在最上面），Windows 下载 `ZerkPlay-Public-Windows-setup.exe`，Android TV 下载 `ZerkPlay-Public-Android.apk`，Linux 下载 `ZerkPlay-Public-Linux-x64.tar.gz`（需自行安装 mpv，解压后运行 `zerk-play/zerk_play`；Arch 用户可用 [`linux/packaging/PKGBUILD`](linux/packaging/PKGBUILD) 构建软件包）。
2. 首次启动时，选择 **Emby 或 Jellyfin** 并登录。
3. *（可选）* 添加免费的 **TMDB API Key**，解锁多语言元数据、标签和合集。
4. *（可选）* 添加 **Seerr** 地址和 API Key，开启求片功能。

> Seerr 地址必须能从运行 Zerk Play 的设备访问。除非 Seerr 就跑在同一台机器上，否则不要填 `localhost`。

## 注意事项

- **Jellyfin 支持是全新的。** 本项目针对 Emby 开发，只在 Jellyfin 上做过少量测试，遇到问题请反馈。
- APK 不上架 Play 商店：可用 Downloader、Send Files to TV 或 adb 安装。
- 已在 Windows 11、Arch Linux 和 Chromecast with Google TV 4K 上测试。其他发行版和 Android TV 盒子理论上也能用，欢迎反馈。
- 服务器和 API Key 由你自己提供。公开构建版本里没有任何硬编码的配置。
- Zerk Play 与 Emby、Jellyfin、Seerr、TMDB 均无隶属关系。
- Linux 播放器图标（`assets/mpv/fonts/MaterialIcons-Player.otf`）是 Google [Material Icons](https://github.com/google/material-design-icons) 的子集，遵循 Apache License 2.0 使用。

非常欢迎反馈、Bug 报告和功能建议：提 Issue 或加入 Discord。
