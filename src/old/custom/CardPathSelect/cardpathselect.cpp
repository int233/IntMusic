#include "cardpathselect.h"

CardPathSelect::CardPathSelect(const QString &title, const QString &subtitle, QWidget *parent)
    : QWidget{parent}, configManager(ConfigManager::instance())
{
    intSetting = configManager.getSettings();

    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(5);

    MainSubTitle *titlesLayout = new MainSubTitle(title, subtitle, this);


    pathListWidget = new QListWidget(this);
    pathListWidget->setStyleSheet("QListWidget { border: 1px solid #ccc; border-radius: 4px; padding: 5px; }");

    addButton = new QPushButton("添加路径", this);
    addButton->setStyleSheet("QPushButton { background-color: #0078D4; color: white; border: none; padding: 5px 10px; border-radius: 4px; }"
                             "QPushButton:hover { background-color: #005BB5; }");

    loadPaths();

    connect(addButton, &QPushButton::clicked, this, &CardPathSelect::onAddButtonClicked);


    layout->addWidget(titlesLayout);
    layout->addWidget(pathListWidget);
    layout->addWidget(addButton);

}


void CardPathSelect::loadPaths()
{
    // 清空列表
    pathListWidget->clear();

    // 从配置中读取路径
    QStringList paths = intSetting->value("Common/MusicFolderPath").toStringList();

    if (paths.isEmpty()) {
        // 如果配置项不存在，调用 GetMusicFolderPath 获取默认路径
        QString defaultPath = configManager.GetMusicFolderPath();
        if (!defaultPath.isEmpty()) {
            paths.append(defaultPath);
            savePathsToConfig(paths); // 保存到配置
        }
    }

    // 将路径添加到列表
    for (const QString &path : paths) {
        qDebug() << "Path: " << path;
        addPathToList(path);
    }
}


void CardPathSelect::addPathToList(const QString &path)
{
    // 创建列表项
    QListWidgetItem *item = new QListWidgetItem(path);
    pathListWidget->addItem(item);

    // 创建自定义控件（用于显示路径和删除按钮）
    QWidget *widget = new QWidget(this);
    QHBoxLayout *layout = new QHBoxLayout(widget);
    layout->setContentsMargins(5, 2, 5, 2); // 设置边距

    // 路径标签
    QLabel *pathLabel = new QLabel(path, widget);
    pathLabel->setStyleSheet("color: #333; font-size: 12px;");
    pathLabel->setWordWrap(true); // 支持换行

    // 删除按钮
    QPushButton *removeButton = new QPushButton("-", widget);
    removeButton->setStyleSheet("QPushButton { background-color: #FF4444; color: white; border: none; padding: 2px 8px; border-radius: 2px; }"
                                "QPushButton:hover { background-color: #CC0000; }");
    removeButton->setFixedSize(20, 20);

    // 将路径标签和删除按钮添加到布局
    layout->addWidget(pathLabel, 1); // 路径标签占据剩余空间
    layout->addWidget(removeButton); // 删除按钮固定宽度

    // 设置自定义控件
    widget->setLayout(layout);
    pathListWidget->setItemWidget(item, widget);

    // 连接删除按钮的点击事件
    connect(removeButton, &QPushButton::clicked, this, &CardPathSelect::onRemoveButtonClicked);
}

void CardPathSelect::savePathsToConfig(const QStringList &paths)
{
    // 保存路径到配置
    intSetting->setValue("Common/MusicFolderPath", paths);
    intSetting->sync(); // 同步配置
    emit pathsUpdated(paths); // 发射路径更新信号
}

void CardPathSelect::onAddButtonClicked()
{
    // 打开文件夹选择对话框
    QString dir = QFileDialog::getExistingDirectory(
        this,
        tr("选择文件夹"),
        QDir::homePath(),
        QFileDialog::ShowDirsOnly | QFileDialog::DontResolveSymlinks
        );

    if (!dir.isEmpty()) {
        // 获取当前路径列表
        QStringList paths = intSetting->value("Common/MusicFolderPath").toStringList();

        // 避免重复添加
        if (!paths.contains(dir)) {
            paths.append(dir);
            savePathsToConfig(paths); // 保存到配置
            addPathToList(dir); // 添加到列表
        } else {
            QMessageBox::warning(this, "提示", "该路径已存在！");
        }
    }
}

void CardPathSelect::onRemoveButtonClicked()
{
    // 获取当前选中的项
    QPushButton *button = qobject_cast<QPushButton *>(sender());
    if (!button) return;

    // 找到对应的列表项
    for (int i = 0; i < pathListWidget->count(); ++i) {
        QListWidgetItem *item = pathListWidget->item(i);
        QWidget *widget = pathListWidget->itemWidget(item);
        if (widget && widget->layout() && widget->layout()->indexOf(button) != -1) {
            // 从配置中移除路径
            QStringList paths = intSetting->value("Common/MusicFolderPath").toStringList();
            paths.removeAll(item->text());
            savePathsToConfig(paths); // 保存到配置

            // 从列表中移除项
            delete item;
            break;
        }
    }
}
