part of '../intmusic_client.dart';

class _ErrorHistoryPanel extends StatelessWidget {
  const _ErrorHistoryPanel();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: ClientLog.errors.entries,
    builder: (context, entries, _) => Column(
      key: const Key('error-history-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '报错历史 · ${entries.length}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            TextButton.icon(
              key: const Key('view-error-history'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _ErrorHistoryDialog(),
              ),
              icon: const Icon(Icons.history, size: 18),
              label: const Text('查看全部'),
            ),
          ],
        ),
        const Text('关闭提示后仍保留记录。保留最近 200 条，重复报错会合并计数。'),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('暂无报错记录'),
          ),
        for (final entry in entries.take(3)) _ErrorHistoryTile(entry: entry),
      ],
    ),
  );
}

class _ErrorHistoryDialog extends StatelessWidget {
  const _ErrorHistoryDialog();

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(12),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 800, maxHeight: 640),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: 20,
              right: 8,
              top: 8,
              bottom: 8,
            ),
            child: Row(
              children: [
                const Expanded(child: Text('报错历史')),
                IconButton(
                  tooltip: _tr(context, 'Close'),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ValueListenableBuilder(
              valueListenable: ClientLog.errors.entries,
              builder: (_, entries, _) => entries.isEmpty
                  ? const Center(child: Text('暂无报错记录'))
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (_, index) =>
                          _ErrorHistoryTile(entry: entries[index]),
                    ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ErrorHistoryTile extends StatelessWidget {
  const _ErrorHistoryTile({required this.entry});
  final Map<String, Object?> entry;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse('${entry['timestamp']}')?.toLocal();
    final timestamp = date == null ? '' : date.toString().split('.').first;
    final count = (entry['count'] as num?)?.toInt() ?? 1;
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: Text(
          '${entry['message'] ?? entry['event']}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('$timestamp${count > 1 ? ' · 重复 $count 次' : ''}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          final details = const JsonEncoder.withIndent('  ').convert(entry);
          showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('报错详情'),
              content: SizedBox(
                width: 640,
                child: SingleChildScrollView(child: SelectableText(details)),
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: details)),
                  child: const Text('复制详情'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(_tr(context, 'Close')),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
