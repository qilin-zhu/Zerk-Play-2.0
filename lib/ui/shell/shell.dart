import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../app/saved_servers.dart';
import '../../core/emby/server_kind.dart';
import '../../core/log/app_log.dart';
import '../../data/user_profile.dart';
import '../../l10n/l10n.dart';
import '../../playback/live_session.dart' show LiveShare;
import '../../playback/sync/watch_together.dart';
import '../../services/updater/updater.dart';
import '../core/input_mode.dart';
import '../core/navigation.dart';
import '../core/playback_launcher.dart';
import '../core/tv_home.dart';
import '../core/ui_sounds.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../pages/calendar_page.dart';
import '../pages/collections_page.dart';
import '../pages/discover_page.dart';
import '../pages/emby_live_tv_page.dart';
import '../pages/fnos_collections_page.dart';
import '../pages/fnos_home_page.dart';
import '../pages/fnos_library_page.dart';
import '../pages/fnos_search_page.dart';
import '../pages/home_page.dart';
import '../pages/library_page.dart';
import '../pages/live_tv_page.dart';
import '../pages/my_list_page.dart';
import '../pages/profile_page.dart';
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
import '../pages/sign_in_page.dart';
import '../pages/together_page.dart';
import '../theme/tokens.dart';
import '../widgets/exit_app.dart';
import '../widgets/profile_widgets.dart';
import '../widgets/server_menu.dart';
import '../widgets/wall_clock.dart';
import '../widgets/update_dialog.dart';
import '../widgets/zerk_logo.dart';

enum ShellTab {
  search(Icons.search_rounded),
  home(Icons.home_rounded),
  favorites(Icons.favorite_rounded),
  myList(Icons.bookmarks_rounded),
  movies(Icons.movie_rounded),
  shows(Icons.tv_rounded),
  collections(Icons.collections_bookmark_rounded),
  discover(Icons.explore_rounded),
  calendar(Icons.calendar_month_rounded),
  liveTv(Icons.live_tv_rounded),
  together(Icons.groups_rounded),
  profile(Icons.account_circle_rounded),
  settings(Icons.settings_rounded);

  const ShellTab(this.icon);

  final IconData icon;

  String label(L10n l10n) => switch (this) {
        search => l10n.search,
        home => l10n.home,
        favorites => l10n.favorites,
        myList => l10n.myList,
        movies => l10n.movies,
        shows => l10n.shows,
        collections => l10n.collections,
        discover => l10n.discover,
        calendar => l10n.calendar,
        liveTv => l10n.liveTv,
        together => l10n.watchTogether,
        profile => l10n.profile,
        settings => l10n.settings,
      };
}

class Shell extends StatefulWidget {
  const Shell({super.key, this.initialTab = ShellTab.home});

  final ShellTab initialTab;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late ShellTab _tab = widget.initialTab;
  late final _visited = <ShellTab>{widget.initialTab};
  final _railZoneKey = GlobalKey();
  final _pageZoneKeys = {for (final t in ShellTab.values) t: GlobalKey()};
  bool _railFocused = false;

  bool _railHovered = false;
  final _railNodes = {for (final t in ShellTab.values) t: FocusNode(debugLabel: 'rail:${t.name}')};

  /// The Zerk Play mark is the entry point of the server switcher, so it needs
  /// a node of its own to be reachable from the D-pad.
  final _logoNode = FocusNode(debugLabel: 'rail:logo');

  /// Rail refresh entry, right above Settings: re-pulls the current server's
  /// data (Emby/Jellyfin/fnOS alike) without signing out and back in.
  final _refreshNode = FocusNode(debugLabel: 'rail:refresh');

  /// Bumped by the rail refresh; every live page is keyed with it so the pages
  /// rebuild from scratch, which re-runs their `initState` reload.
  int _refreshEpoch = 0;
  bool _refreshing = false;

  /// Where the switcher panel hangs: the follower tracks the logo's paint
  /// position, so the panel stays glued to the right of the mark even while the
  /// rail is still animating open.
  final _logoLink = LayerLink();

  bool _menuOpen = false;
  StreamSubscription<RoomState>? _roomSub;
  String? _roomCode;

  @override
  void initState() {
    super.initState();
    AppLog.write('[shell] build server-menu-v2 (dropdown below the mark, glass panel, brand icons)');
    if (kReleaseMode && Updater.supported) {
      Future.delayed(const Duration(seconds: 5), () => mounted ? checkForUpdate(context) : null);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_roomSub == null) {
      _services = AppServicesScope.read(context);
      _roomSub = _services.together.updates.listen(_onRoom);
      playbackActiveNotifier.addListener(_onPlayback);
      if (TvHome.supported) _watchTvHome();
    }
  }

  late final AppServices _services;
  AppLifecycleListener? _lifecycle;
  Timer? _tvHomeTimer;

  void _watchTvHome() {
    _services.libraryChanged.addListener(_scheduleTvHome);
    _lifecycle = AppLifecycleListener(onHide: _publishTvHome);
    _tvHomeTimer = Timer(const Duration(seconds: 10), _publishTvHome);
    TvHome.onLaunch(_openLaunch);
    unawaited(_openLaunch());
  }

  void _scheduleTvHome() {
    _tvHomeTimer?.cancel();
    _tvHomeTimer = Timer(const Duration(seconds: 3), _publishTvHome);
  }

  Future<void> _publishTvHome() async {
    _tvHomeTimer?.cancel();
    if (!_services.isSignedIn || _isFnos) return;
    try {
      await TvHome.publish(_services.catalog);
    } catch (e) {
      debugPrint('[tvhome] publish: $e');
    }
  }

  Future<void> _openLaunch() async {
    if (_isFnos) return;
    final id = await TvHome.takeLaunch();
    if (id == null || !mounted || playbackActive) return;
    debugPrint('[tvhome] launched for $id');
    try {
      final item = await _services.catalog.item(id);
      if (mounted && !playbackActive) await playItem(context, item);
    } catch (e) {
      debugPrint('[tvhome] could not open $id: $e');
    }
  }

  Future<void> _onRoom(RoomState room) async {
    final joined = room.code != _roomCode;
    _roomCode = room.code;
    if (!joined && room.rev == _roomRev) return;
    _roomRev = room.rev;
    final together = AppServicesScope.read(context).together;
    final itemId = room.itemId;
    if (itemId == null || room.by == together.me) return;
    final started = room.action == 'item' || (joined && room.members.any((m) => m.watching == itemId));
    if (!started) return;
    if (playbackActive) {
      if (room.live != null || liveActive) _followWhenClosed = true;
      return;
    }
    await _open(room);
  }

  int _roomRev = -1;

  bool _followWhenClosed = false;

  void _onPlayback() {
    if (playbackActiveNotifier.value || !_followWhenClosed) return;
    _followWhenClosed = false;
    final together = AppServicesScope.read(context).together;
    final room = together.room;
    if (room?.itemId == null || !room!.members.any((m) => m.id != together.me && m.watching == room.itemId)) return;
    unawaited(_open(room));
  }

  Future<void> _open(RoomState room) async {
    final live = LiveShare.fromRoom(room);
    if (live != null) {
      await playShared(context, live);
      return;
    }
    try {
      final item = await AppServicesScope.read(context).catalog.item(room.itemId!);
      if (mounted && !playbackActive) await playItem(context, item);
    } catch (e) {
      debugPrint("[together] could not open the room's item: $e");
    }
  }

  @override
  void dispose() {
    unawaited(_roomSub?.cancel());
    playbackActiveNotifier.removeListener(_onPlayback);
    _services.libraryChanged.removeListener(_scheduleTvHome);
    _lifecycle?.dispose();
    _tvHomeTimer?.cancel();
    if (TvHome.supported && !_services.isSignedIn) unawaited(TvHome.clear());
    for (final n in _railNodes.values) {
      n.dispose();
    }
    _logoNode.dispose();
    _refreshNode.dispose();
    super.dispose();
  }

  /// Rail refresh: drop every live page so they reload from the current server
  /// (Emby, Jellyfin or 飞牛影视 — whichever session is active). Pages keep
  /// their data in `initState`, so a rebuild is the only reliable way to make
  /// all of them catch up after the library changed somewhere else.
  void _refreshService() {
    if (_refreshing) return;
    final fnos = _isFnos;
    AppLog.write('[shell] refresh ${fnos ? 'fnos' : 'emby'} tab=${_tab.name}');
    setState(() {
      _refreshing = true;
      _refreshEpoch++;
    });
    // Feedback for the spinner: the pages reload on their own schedules, so the
    // rail just shows that the press was taken.
    Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _refreshing = false);
    });
  }

  bool get _isFnos => _services.isSignedIn && _services.janus.session.kind == ServerKind.fnos;

  List<ShellTab> _tabs(AppServices s) {
    // 飞牛影视 sessions browse fnOS data: only the backend-independent tabs are
    // offered (search/library/discover/calendar query the Emby catalog, the
    // profile belongs to the Emby user).
    if (_isFnos) {
      return [
        ShellTab.search,
        ShellTab.home,
        ShellTab.myList,
        ShellTab.favorites,
        ShellTab.movies,
        ShellTab.shows,
        ShellTab.collections,
        if (s.liveTvAvailable) ShellTab.liveTv,
        // Settings must be a real tab: the body only renders pages for tabs in
        // this list and resets unknown tabs back to home, so omitting it made
        // the rail's settings entry a no-op.
        ShellTab.settings,
      ];
    }
    return [
      for (final t in ShellTab.values)
        if ((t != ShellTab.discover || s.seerr != null) && (t != ShellTab.calendar || s.tmdb != null || s.seerr != null) &&
            (t != ShellTab.liveTv || s.liveTvAvailable || s.embyTvAvailable) &&
            (t != ShellTab.together || s.together.available) &&
            ((t != ShellTab.myList && t != ShellTab.profile) || s.profiles.profile != null)) t,
    ];
  }

  void _select(ShellTab tab) {
    final firstVisit = !_visited.contains(tab);
    final watch = Stopwatch()..start();
    AppLog.where = 'tab:${tab.name}';
    WidgetsBinding.instance.addPostFrameCallback((_) => AppLog.write(
        '[nav] tab ${tab.name}${firstVisit ? ' (first visit)' : ''}: first frame after ${watch.elapsedMilliseconds} ms'));
    setState(() {
      _tab = tab;
      _visited.add(tab);
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ZoneNavigator.move(TraversalDirection.right),
    );
  }

  bool _onBack() {
    if (_menuOpen) {
      UiSounds.play(UiSound.back);
      _closeMenu();
      return true;
    }
    if (!_railFocused) {
      _focusRail();
      UiSounds.play(UiSound.back);
      return true;
    }
    if (_tab != ShellTab.home) {
      UiSounds.play(UiSound.back);
      _select(ShellTab.home);
      return true;
    }
    UiSounds.play(UiSound.back);
    confirmExit(context);
    return true;
  }

  void _focusRail() {
    final zone = FocusZone.nodeOf(_railZoneKey);
    if (zone != null) ZoneNavigator.enter(zone);
  }

  /// Identity of the open session, compared against [SavedServer.serverKey] so
  /// the switcher can mark — and skip — the server that is already running.
  String? get _serverKey {
    if (!_services.isSignedIn) return null;
    final session = _services.janus.session;
    return SavedServer.keyOf('${session.serverUrl}', session.kind);
  }

  void _openMenu() {
    if (_menuOpen) return;
    debugPrint('[servers] switcher open: ${_services.servers.items.length} saved');
    setState(() => _menuOpen = true);
  }

  void _closeMenu({bool restoreFocus = true}) {
    if (!_menuOpen) return;
    setState(() => _menuOpen = false);
    if (restoreFocus) _focusRail();
  }

  /// "Add server" in the switcher: the manual form, pushed over the shell so it
  /// can be dismissed again. Signing in there records the account, so it shows
  /// up in the list as soon as the route pops.
  void _addServer() {
    final navigator = Navigator.of(context);
    _closeMenu(restoreFocus: false);
    navigator.push(MaterialPageRoute(builder: (_) => const SignInPage(startManual: true, addServer: true)));
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServicesScope.of(context);
    final tabs = _tabs(services);
    if (!tabs.contains(_tab)) _tab = ShellTab.home;

    return BackHandler(
      onBack: _onBack,
      child: Material(
        color: Zc.background,
        child: ValueListenableBuilder(
          valueListenable: InputMode.pointer,
          builder: (context, pointer, _) {
            // The rail widens while the switcher is open, so the panel can be
            // anchored to its right edge without measuring anything.
            final railExpanded = _menuOpen || (_railFocused && (!pointer || _railHovered));
            // The app mark in the rail's corner stays hidden until the rail is
            // actually in use: over artwork it is the first thing the eye lands
            // on, and every page looks cleaner without it. Hovering the rail or
            // giving it keyboard focus brings it back (the switcher needs it as
            // its anchor, so an open switcher always shows it).
            final logoVisible = _menuOpen || _railHovered || _railFocused;
            // The panel starts under the mark (~110 px down), so it can use
            // whatever is left of the window minus a bottom margin.
            final panelHeight = (MediaQuery.sizeOf(context).height - 140).clamp(300.0, 720.0).toDouble();
            return Stack(
              children: [
                // While the switcher is open the page must not take the focus:
                // a Right press inside the panel would otherwise land on the
                // artwork behind it.
                Positioned.fill(
                  child: ExcludeFocus(
                    excluding: _menuOpen,
                    child: Stack(
                      children: [
                        for (final t in tabs)
                          if (_visited.contains(t))
                            Offstage(
                              key: _pageZoneKeys[t],
                              offstage: t != _tab,
                              child: TickerMode(
                                enabled: t == _tab,
                                child: ExcludeFocus(
                                  excluding: t != _tab,
                                  // Keyed by the refresh epoch: a rail refresh
                                  // rebuilds the page from scratch, which re-runs
                                  // its initState reload against the server.
                                  child: KeyedSubtree(
                                    key: ValueKey('${t.name}#$_refreshEpoch'),
                                    child: _page(t),
                                  ),
                                ),
                              ),
                            ),
                        if (services.settings.homeClock && _tab == ShellTab.home)
                          const Positioned(
                              top: 44, right: 72, child: IgnorePointer(child: WallClock(shadow: true))),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: ValueListenableBuilder(
                    valueListenable: HomePage.firstLoad,
                    builder: (context, loading, rail) {
                      // HomePage.firstLoad only settles for the Emby home; the
                      // fnOS home never touches it, so the rail must not key off
                      // it there.
                      final hidden = loading && _tab == ShellTab.home && !_isFnos;
                      return IgnorePointer(
                        ignoring: hidden,
                        child: ExcludeFocus(
                          excluding: hidden,
                          child: AnimatedOpacity(
                              opacity: hidden ? 0 : 1, duration: const Duration(milliseconds: 600), child: rail),
                        ),
                      );
                    },
                    child: MouseRegion(
                      onEnter: (_) => setState(() => _railHovered = true),
                      onExit: (_) => setState(() => _railHovered = false),
                      child: Focus(
                        canRequestFocus: false,
                        skipTraversal: true,
                        onFocusChange: (f) => setState(() => _railFocused = f),
                        child: FocusZone(
                          key: _railZoneKey,
                          debugLabel: 'rail',
                          preferredEntry: () => _railNodes[_tab],
                          child: _Rail(
                            tabs: tabs,
                            profile: services.profiles.profile,
                            current: _tab,
                            expanded: railExpanded,
                            logoVisible: logoVisible,
                            menuOpen: _menuOpen,
                            logoNode: _logoNode,
                            logoLink: _logoLink,
                            refreshNode: _refreshNode,
                            refreshing: _refreshing,
                            onRefresh: _refreshService,
                            onOpenServers: _openMenu,
                            onSelect: _select,
                            nodes: _railNodes,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_menuOpen) ...[
                  // Any click that is not on the panel dismisses it, the same
                  // way the sheet-like switcher behaves in the reference.
                  Positioned.fill(
                    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _closeMenu),
                  ),
                  // A plain dropdown: hangs off the bottom-left corner of the
                  // mark, so it covers the nav items exactly like a menu under
                  // any other header.
                  CompositedTransformFollower(
                    link: _logoLink,
                    targetAnchor: Alignment.bottomLeft,
                    followerAnchor: Alignment.topLeft,
                    offset: const Offset(0, 12),
                    showWhenUnlinked: false,
                    child: ServerMenuPanel(
                      currentKey: _serverKey,
                      height: panelHeight,
                      onClose: _closeMenu,
                      onAdd: _addServer,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _page(ShellTab t) {
    if (_isFnos) {
      return switch (t) {
        ShellTab.home => const FnOsHomePage(),
        ShellTab.search => const FnOsSearchPage(),
        ShellTab.myList || ShellTab.favorites => const FnOsLibraryPage(kind: FnOsLibraryKind.favorites),
        ShellTab.movies => const FnOsLibraryPage(kind: FnOsLibraryKind.movies),
        ShellTab.shows => const FnOsLibraryPage(kind: FnOsLibraryKind.shows),
        ShellTab.collections => const FnOsCollectionsPage(),
        ShellTab.liveTv => const LiveTvPage(),
        _ => const SettingsPage(),
      };
    }
    return switch (t) {
      ShellTab.home => const HomePage(),
      ShellTab.search => const SearchPage(),
      ShellTab.movies => const LibraryPage(kind: LibraryKind.movies),
      ShellTab.shows => const LibraryPage(kind: LibraryKind.shows),
      ShellTab.favorites => const LibraryPage(kind: LibraryKind.favorites),
      ShellTab.collections => const CollectionsPage(),
      ShellTab.discover => const DiscoverPage(),
      ShellTab.calendar => const CalendarPage(),
      ShellTab.liveTv => AppServicesScope.read(context).liveTvAvailable ? const LiveTvPage() : const EmbyLiveTvPage(),
      ShellTab.together => const TogetherPage(),
      ShellTab.myList => const MyListPage(),
      ShellTab.profile => const ProfilePage(),
      ShellTab.settings => const SettingsPage(),
    };
  }
}

enum _Group {
  library(Icons.video_library_rounded, [ShellTab.movies, ShellTab.shows, ShellTab.collections]),
  explore(Icons.explore_rounded, [ShellTab.discover, ShellTab.calendar]);

  const _Group(this.icon, this.tabs);

  final IconData icon;
  final List<ShellTab> tabs;

  String label(L10n l10n) => switch (this) {
        library => l10n.navLibrary,
        explore => l10n.navExplore,
      };
}

const List<Object> _railOrder = [
  ShellTab.search,
  ShellTab.home,
  ShellTab.myList,
  ShellTab.favorites,
  _Group.library,
  _Group.explore,
  ShellTab.liveTv,
  ShellTab.together,
];

class _Rail extends StatefulWidget {
  const _Rail({
    required this.tabs,
    required this.profile,
    required this.current,
    required this.expanded,
    required this.logoVisible,
    required this.menuOpen,
    required this.logoNode,
    required this.logoLink,
    required this.refreshNode,
    required this.refreshing,
    required this.onRefresh,
    required this.onOpenServers,
    required this.onSelect,
    required this.nodes,
  });

  /// Width of the collapsed rail. It is a translucent overlay on top of the
  /// page (the artwork runs underneath it), so it is kept narrow and the
  /// content insets stay where they were.
  static const collapsedWidth = 76.0;
  static const expandedWidth = Zs.railExpanded + 120;

  final Map<ShellTab, FocusNode> nodes;
  final List<ShellTab> tabs;

  final UserProfile? profile;
  final ShellTab current;
  final bool expanded;

  /// Whether the app mark in the corner is on screen: true only while the rail
  /// is hovered, focused or has its switcher open.
  final bool logoVisible;

  /// The server switcher is showing: the logo keeps its chevron turned down.
  final bool menuOpen;
  final FocusNode logoNode;
  final LayerLink logoLink;

  /// Reload entry above Settings: spins while [_refreshing] is set.
  final FocusNode refreshNode;
  final bool refreshing;
  final VoidCallback onRefresh;

  final VoidCallback onOpenServers;
  final ValueChanged<ShellTab> onSelect;

  @override
  State<_Rail> createState() => _RailState();
}

class _RailState extends State<_Rail> {
  final _groupNodes = {for (final g in _Group.values) g: FocusNode(debugLabel: 'rail-group:${g.name}')};

  _Group? _focusGroup;

  @override
  void dispose() {
    for (final n in _groupNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  bool _open(_Group g) =>
      widget.expanded && (_focusGroup == g || (_focusGroup == null && g.tabs.contains(widget.current)));

  Widget _item(ShellTab t, {bool child = false}) => _RailItem(
        tab: t,
        node: widget.nodes[t]!,
        selected: t == widget.current,
        expanded: widget.expanded,
        child: child,
        profile: t == ShellTab.profile ? widget.profile : null,
        onSelect: () => widget.onSelect(t),
      );

  Widget _group(_Group g, List<ShellTab> tabs) {
    final open = _open(g);
    final holdsCurrent = tabs.contains(widget.current);
    final focusable = open || (!widget.expanded && holdsCurrent);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() {
        if (f) {
          _focusGroup = g;
        } else if (_focusGroup == g) {
          _focusGroup = null;
        }
      }),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        _RailItem(
          icon: g.icon,
          label: g.label(context.l10n),
          node: _groupNodes[g]!,
          selected: holdsCurrent,
          expanded: widget.expanded,
          open: open,
          onSelect: () => widget.onSelect(holdsCurrent ? widget.current : tabs.first),
        ),
        ClipRect(
          child: AnimatedAlign(
            duration: Zm.normal,
            curve: Zm.curve,
            alignment: Alignment.topLeft,
            heightFactor: open ? 1 : 0,
            child: ExcludeFocus(
              excluding: !focusable,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final t in tabs) _item(t, child: true),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs;
    final expanded = widget.expanded;
    return AnimatedContainer(
      duration: Zm.normal,
      curve: Zm.curve,
      width: expanded ? _Rail.expandedWidth : _Rail.collapsedWidth,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          // Collapsed, the glyph column sits at roughly half the rail's 76 px
          // width, so the scrim has to stay dark past 0.5 - otherwise the icons
          // land on artwork that is already washed out to ~20% black and white
          // glyphs disappear over a bright poster.
          stops: expanded ? const [0, 0.55, 1] : const [0, 0.64, 1],
          colors: expanded
              ? const [Color(0xF20B0B12), Color(0xE00B0B12), Color(0x000B0B12)]
              // A translucent scrim, never a solid bar: the artwork still reads
              // through it, but the glyphs always have something dark to sit on.
              : const [Color(0xBD000000), Color(0x70000000), Color(0x00000000)],
        ),
      ),
      padding: EdgeInsets.only(left: expanded ? 20 : 6, top: 48, bottom: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fades out of the way (and slightly down in scale) when the rail is
          // idle. It is never removed from the tree: it is the D-pad's way into
          // the server switcher, and focusing it is what makes it visible again.
          AnimatedOpacity(
            opacity: widget.logoVisible ? 1 : 0,
            duration: Zm.normal,
            curve: Zm.curve,
            child: AnimatedScale(
              scale: widget.logoVisible ? 1 : 0.86,
              duration: Zm.normal,
              curve: Zm.curve,
              alignment: Alignment.centerLeft,
              child: _Logo(
                expanded: expanded,
                open: widget.menuOpen,
                node: widget.logoNode,
                link: widget.logoLink,
                onSelect: widget.onOpenServers,
              ),
            ),
          ),
          const Spacer(),
          for (final entry in _railOrder)
            if (entry is ShellTab && tabs.contains(entry))
              _item(entry)
            else if (entry is _Group)
              switch (entry.tabs.where(tabs.contains).toList()) {
                [] => const SizedBox.shrink(),
                [final only] => _item(only),
                final some => _group(entry, some),
              },
          const Spacer(),
          if (tabs.contains(ShellTab.profile)) _item(ShellTab.profile),
          _RailItem(
            icon: Icons.refresh_rounded,
            label: context.l10n.navRefresh,
            node: widget.refreshNode,
            selected: false,
            expanded: expanded,
            busy: widget.refreshing,
            onSelect: widget.onRefresh,
          ),
          _item(ShellTab.settings),
        ],
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({
    required this.expanded,
    required this.open,
    required this.node,
    required this.link,
    required this.onSelect,
  });

  final bool expanded;
  final bool open;
  final FocusNode node;
  final LayerLink link;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      // The whole mark is the button: the chevron alone would be a tiny target,
      // and on the D-pad it is the only way into the server switcher. The
      // composited target is what the switcher panel hangs off.
      child: CompositedTransformTarget(
        link: link,
        child: TvFocusable(
          focusNode: node,
          reveal: false,
          onSelect: onSelect,
          builder: (context, focused) => AnimatedContainer(
            duration: Zm.fast,
            curve: Zm.curve,
            padding: EdgeInsets.only(right: expanded ? 14 : 0),
            decoration: BoxDecoration(
              color: focused ? Colors.white.withValues(alpha: 0.10) : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ZerkLogo(size: 48),
                if (expanded)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text.rich(
                              const TextSpan(children: [
                                TextSpan(text: 'Zerk', style: TextStyle(fontWeight: FontWeight.w800)),
                                TextSpan(
                                    text: ' Play', style: TextStyle(fontWeight: FontWeight.w400, color: Zc.textMuted)),
                              ]),
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: Zt.title.copyWith(height: 1),
                            ),
                          ),
                          const SizedBox(width: 8),
                          AnimatedRotation(
                            turns: open ? 0.5 : 0,
                            duration: Zm.normal,
                            curve: Zm.curve,
                            child: Icon(Icons.expand_more_rounded,
                                size: 28, color: focused ? Colors.white : Zc.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    this.tab,
    this.icon,
    this.label,
    required this.node,
    required this.selected,
    required this.expanded,
    required this.onSelect,
    this.child = false,
    this.open,
    this.profile,
    this.busy = false,
  });

  final ShellTab? tab;
  final IconData? icon;
  final String? label;

  final bool child;

  final bool? open;

  final UserProfile? profile;
  final FocusNode node;
  final bool selected;
  final bool expanded;

  /// Spins the glyph while the action behind it is running (rail refresh).
  final bool busy;

  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final group = open != null;
    return Padding(
      padding: EdgeInsets.only(top: 3, bottom: 3, left: child && expanded ? 26 : 0),
      child: TvFocusable(
        focusNode: node,
        reveal: false,
        onSelect: onSelect,
        builder: (context, focused) {
          // Over artwork the glyph needs more than the global "faint" 45% white:
          // white at that opacity is invisible against a bright poster, and the
          // rail is the only navigation on screen.
          final fg = focused
              ? Zc.background
              : (selected ? Colors.white : (child ? Zc.textMuted : const Color(0xD9FFFFFF)));
          return AnimatedContainer(
            duration: Zm.fast,
            curve: Zm.curve,
            height: child ? 50 : 58,
            width: expanded ? Zs.railExpanded - 20 - (child ? 26 : 0) : 64,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: focused
                  ? Colors.white
                  // The selected pill is a dark wash plus a hairline, so it reads
                  // both ways: it dims against a bright poster and the outline
                  // still shows on a dark one.
                  : (selected && !expanded ? const Color(0x4D000000) : Colors.transparent),
              border: selected && !expanded && !focused
                  ? Border.all(color: const Color(0x3DFFFFFF))
                  : null,
              borderRadius: BorderRadius.circular(30),
            ),
            clipBehavior: Clip.hardEdge,
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: Zs.railExpanded - 56 - (child ? 26 : 0),
              maxWidth: Zs.railExpanded - 56 - (child ? 26 : 0),
              child: Row(
                children: [
                  if (profile != null)
                    SizedBox(
                      width: 28,
                      height: 40,
                      child: OverflowBox(
                        maxWidth: 40,
                        child: UserAvatar(
                            url: profile!.avatarUrl, name: profile!.name, size: 40, ring: focused ? Zc.accent : null),
                      ),
                    )
                  else
                    _RailGlyph(
                      icon: icon ?? tab!.icon,
                      size: child ? 24 : 28,
                      color: fg,
                      // Collapsed, the rail floats over the artwork: a soft
                      // shadow keeps the glyph readable on bright posters.
                      shadow: !expanded,
                      busy: busy,
                    ),
                  if (expanded)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 18),
                        child: Text(
                          profile?.name ?? label ?? tab!.label(context.l10n),
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: Zt.label.copyWith(color: fg, fontSize: child ? 20 : 22),
                        ),
                      ),
                    ),
                  if (expanded && group)
                    AnimatedRotation(
                      turns: open! ? 0.5 : 0,
                      duration: Zm.normal,
                      child: Icon(Icons.expand_more_rounded, size: 26, color: fg),
                    )
                  else if (expanded && selected && !focused)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Zc.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Rail glyph that keeps a fixed footprint. While [busy] it spins, which is the
/// only feedback a refresh can give: the reloads it starts finish on the pages'
/// own schedules.
class _RailGlyph extends StatefulWidget {
  const _RailGlyph({
    required this.icon,
    required this.size,
    required this.color,
    required this.shadow,
    this.busy = false,
  });

  final IconData icon;
  final double size;
  final Color color;
  final bool shadow;
  final bool busy;

  @override
  State<_RailGlyph> createState() => _RailGlyphState();
}

class _RailGlyphState extends State<_RailGlyph> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.busy) _spin.repeat();
  }

  @override
  void didUpdateWidget(_RailGlyph old) {
    super.didUpdateWidget(old);
    if (widget.busy == old.busy) return;
    if (widget.busy) {
      _spin.repeat();
    } else {
      // Finish the turn already in progress so the icon never snaps back.
      _spin.animateTo(1, duration: const Duration(milliseconds: 240))
          .whenComplete(() => _spin.value = 0);
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _spin,
      child: Icon(
        widget.icon,
        size: widget.size,
        color: widget.color,
        // A single wide blur leaves thin 2 px strokes with almost no outline -
        // over a bright poster the glyph still washed out. Stacking a tight
        // shadow under two progressively wider ones draws a dark edge that
        // actually separates the stroke from the artwork.
        shadows: widget.shadow
            ? const [
                Shadow(color: Color(0xE6000000), blurRadius: 3),
                Shadow(color: Color(0xB3000000), blurRadius: 9),
                Shadow(color: Color(0x80000000), blurRadius: 20),
              ]
            : null,
      ),
    );
  }
}
