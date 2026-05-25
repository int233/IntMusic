part of '../main.dart';

enum _AppLanguage { en, zh }

class _LocaleScope extends InheritedWidget {
  const _LocaleScope({required this.language, required super.child});

  final _AppLanguage language;

  static _AppLanguage languageOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<_LocaleScope>()
            ?.language ??
        _AppLanguage.en;
  }

  @override
  bool updateShouldNotify(_LocaleScope oldWidget) =>
      oldWidget.language != language;
}

String _tr(BuildContext context, String text) {
  if (_LocaleScope.languageOf(context) == _AppLanguage.en) {
    return text;
  }
  return _zh[text] ?? text;
}

const _zh = <String, String>{
  'Home': '主页',
  'Albums': '专辑',
  'Singles': '单曲',
  'Artists': '艺术家',
  'Tracks': '歌曲',
  'Album': '专辑',
  'Album detail': '专辑详情',
  'Artist detail': '艺术家详情',
  'Search': '搜索',
  'Playlists': '歌单',
  'Playback': '播放',
  'History': '历史',
  'Settings': '设置',
  'Diagnostics': '诊断',
  'Menu': '菜单',
  'Library': '音乐库',
  'Search library': '搜索音乐库',
  'Search results': '搜索结果',
  'Suggestions': '候选结果',
  'All': '全部',
  'Relevance': '相关度',
  'Title A-Z': '标题 A-Z',
  'Album A-Z': '专辑 A-Z',
  'Artist A-Z': '歌手 A-Z',
  'File size': '文件大小',
  'Added time': '添加时间',
  'Play count': '播放次数',
  'Favorite': '收藏',
  'Filter': '筛选',
  'Sort': '排序',
  'Online': '在线',
  'outputs': '输出',
  'Core Server': '核心服务',
  'Aliases': '别名',
  'Server alias': '服务端别名',
  'Client alias': '客户端别名',
  'Core URL': 'Core 地址',
  'Connect': '连接',
  'Discover': '发现',
  'Scan': '扫描',
  'Music folders': '音乐文件夹',
  'Core-side folder path': 'Core 侧文件夹路径',
  'Use a path that the Core server can access': '请填写 Core 服务端可以访问的路径',
  'Browse': '浏览',
  'Add folder': '添加文件夹',
  'Rescan library': '重新扫描音乐库',
  'No music folders configured': '还没有配置音乐文件夹',
  'Remove': '移除',
  'Renderer': '播放端',
  'Version': '版本',
  'API': 'API',
  'Database': '数据库',
  'Favorites': '收藏',
  'Max rating counts as favorite': '最高评分视作收藏',
  'RATING 5/5, 100/100, or POPM 255 is shown as favorite':
      'RATING 5/5、100/100 或 POPM 255 会显示为收藏',
  'Favorite writes max rating': '收藏时写入最高评分',
  'Writes the maximum rating tag when enabled': '启用后收藏会写入最高评分标签',
  'Language': '语言',
  'Interface language': '界面语言',
  'English': '英文',
  'Chinese': '中文',
  'Not playing': '未播放',
  'No active track': '没有正在播放的歌曲',
  'Unknown Artist': '未知艺术家',
  'Select a track': '选择歌曲',
  'Track detail': '歌曲详情',
  'Lyrics': '歌词',
  'No embedded lyrics': '没有内嵌歌词',
  'Queue': '待播放',
  'No upcoming tracks': '没有待播放歌曲',
  'Open queue': '打开待播放列表',
  'Devices': '设备',
  'DLNA': 'DLNA',
  'Details': '详情',
  'Lyrics page': '歌词页',
  'Player page': '播放页',
  'Playback devices': '播放设备',
  'Device alias': '设备别名',
  'Alias': '别名',
  'Rename': '重命名',
  'Edit rules': '编辑规则',
  'Edit Smart Playlist': '编辑智能歌单',
  'Clear': '清空',
  'Cancel': '取消',
  'Close': '关闭',
  'Save': '保存',
  'Zones': '播放区域',
  'No playback zones': '没有播放设备',
  'No albums': '没有专辑',
  'No results': '没有结果',
  'Play everywhere': '全体设备播放',
  'Stop everywhere': '全体设备停止',
  'Move here': '转移到这里',
  'Metadata separators': '元数据分隔符',
  'Artist / composer / lyricist': '歌手 / 曲作者 / 词作者',
  'Genre': '流派',
  'Separate delimiter tokens with spaces': '多个分隔符请用空格分开',
  'Default: comma and semicolon': '默认：英文逗号和分号',
  'Select': '选择',
  'Stop': '停止',
  'Pause': '暂停',
  'Resume': '继续',
  'Previous': '上一曲',
  'Next': '下一曲',
  'Mode': '播放模式',
  'Single play': '单次播放',
  'Repeat one': '单曲循环',
  'Shuffle': '随机播放',
  'Sequential': '顺序播放',
};
