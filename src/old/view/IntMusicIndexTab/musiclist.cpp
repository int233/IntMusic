#include "musiclist.h"

TabMusicList::TabMusicList(QWidget *parent)
    : QWidget{parent}
{
    QVBoxLayout *mainLayout = new QVBoxLayout(this);
    // 创建 ScrollArea
    QScrollArea *scrollArea = new QScrollArea(this);
    scrollArea->setWidgetResizable(true);  // 允许内容自适应大小

    // 创建 ScrollArea 的内容部件
    QWidget *scrollContent = new QWidget();
    QVBoxLayout *scrollLayout = new QVBoxLayout(scrollContent);

    // 第一部分：搜索框和排序选项
    QWidget *searchAndSortWidget = new QWidget();
    QHBoxLayout *searchAndSortLayout = new QHBoxLayout(searchAndSortWidget);

    // 搜索框
    QLineEdit *searchBox = new QLineEdit();
    searchBox->setPlaceholderText("搜索音乐...");
    searchAndSortLayout->addWidget(searchBox);

    // 排序类型选择
    QComboBox *sortTypeComboBox = new QComboBox();
    sortTypeComboBox->addItem("按文件名排序");
    sortTypeComboBox->addItem("按歌手名排序");
    sortTypeComboBox->addItem("按时长排序");
    searchAndSortLayout->addWidget(sortTypeComboBox);

    // 是否倒序
    QCheckBox *reverseOrderCheckBox = new QCheckBox("倒序");
    searchAndSortLayout->addWidget(reverseOrderCheckBox);

    // 将搜索和排序部分添加到 ScrollArea 的内容布局
    scrollLayout->addWidget(searchAndSortWidget);

    // 第二部分：音乐文件列表
    MusicListView *musicListWidget = new MusicListView(this);


    // 将音乐文件列表添加到 ScrollArea 的内容布局
    scrollLayout->addWidget(musicListWidget);

    // 设置 ScrollArea 的内容部件
    scrollArea->setWidget(scrollContent);

    // 将 ScrollArea 添加到主布局
    mainLayout->addWidget(scrollArea);

    // 设置主布局
    setLayout(mainLayout);

    connect(searchBox, &QLineEdit::textChanged, this, &TabMusicList::onSearchTextChanged);
    connect(sortTypeComboBox, QOverload<int>::of(&QComboBox::currentIndexChanged), this, &TabMusicList::onSortTypeChanged);
    // connect(reverseOrderCheckBox, &QCheckBox::stateChanged, this, &TabMusicList::onReverseOrderChanged);
}


void TabMusicList::onSearchTextChanged(const QString &text)
{
    qDebug() << "搜索内容：" << text;
    // 在这里实现搜索逻辑
}

// 槽函数：处理排序类型变化
void TabMusicList::onSortTypeChanged(int index)
{
    qDebug() << "排序类型：" << index;
    // 在这里实现排序逻辑
}

// 槽函数：处理是否倒序
void TabMusicList::onReverseOrderChanged(int state)
{
    bool reverseOrder = (state == Qt::Checked);
    qDebug() << "是否倒序：" << reverseOrder;
    // 在这里实现倒序逻辑
}
