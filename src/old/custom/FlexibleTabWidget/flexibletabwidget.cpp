#include "flexibletabwidget.h"
#include <QVBoxLayout>

FlexibleTabWidget::FlexibleTabWidget(QWidget *parent)
    : QTabWidget(parent)
{
    // 隐藏原生TabBar
    tabBar()->hide();

    // 创建自定义布局
    QHBoxLayout *mainLayout = new QHBoxLayout(this);
    mainLayout->setContentsMargins(0, 0, 0, 0);
    mainLayout->setSpacing(0);

    // 创建标签容器
    QWidget *tabContainer = new QWidget;
    QVBoxLayout *tabLayout = new QVBoxLayout(tabContainer);
    tabLayout->setContentsMargins(0, 0, 0, 0);
    tabLayout->setSpacing(0);

    // 顶部标签栏
    topBar = new QTabBar(this);
    topBar->setShape(QTabBar::RoundedWest);

    // 中间标签栏
    middleBar = new QTabBar(this);
    middleBar->setShape(QTabBar::RoundedWest);

    // 弹性间隔
    spacer = new QWidget(this);
    spacer->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    // mainLayout->addWidget(spacer);

    // 底部标签栏
    bottomBar = new QTabBar(this);
    bottomBar->setShape(QTabBar::RoundedWest);

    // 设置样式
    // Tab区域宽度
    topBar->setFixedWidth(20);
    middleBar->setFixedWidth(20);
    bottomBar->setFixedWidth(20);

    // 标签添加至标签容器
    tabLayout->addWidget(topBar, 0, Qt::AlignTop);
    tabLayout->addWidget(middleBar, 0, Qt::AlignTop);
    tabLayout->addWidget(spacer, 1); // 弹性间隔
    tabLayout->addWidget(bottomBar, 0, Qt::AlignBottom);

    // 内容区域
    contentArea = new QStackedWidget;
    contentArea->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);

    // 整体布局：左侧标签区（固定宽度）、右侧内容区（弹性扩展）
    mainLayout->addWidget(tabContainer, 0);
    mainLayout->addWidget(contentArea, 1);

    // 初始化信号连接
    updateTabConnections();

    // 初始化默认Tab
    if(topBar->count() >= 0){
        topBar->setCurrentIndex(0);
    }
}

// 更新信号连接（自动计算索引偏移）
void FlexibleTabWidget::updateTabConnections()
{
    connect(topBar, &QTabBar::currentChanged, this, [=](int index){
        if (index >= 0) handleCurrentChange(topBar,index, "Top");
    });

    connect(middleBar, &QTabBar::currentChanged, this, [=](int index){
        if (index >= 0) handleCurrentChange(middleBar,index, "Middle");
    });

    connect(bottomBar, &QTabBar::currentChanged, this, [=](int index){
        if (index >= 0) handleCurrentChange(bottomBar,index, "Bottom");
    });

    connect(topBar, &QTabBar::tabBarClicked, this, [=](int index){
        if (index >= 0) handleClicked(topBar,"Top");
    });

    connect(middleBar, &QTabBar::tabBarClicked, this, [=](int index){
        if (index >= 0) handleClicked(middleBar,"Middle");
    });

    connect(bottomBar, &QTabBar::tabBarClicked, this, [=](int index){
        if (index >= 0) handleClicked(bottomBar,"Bottom");
    });

}

void FlexibleTabWidget::handleClicked(QTabBar* activeBar, const QString &type) {
    int contentIndex = getIndex(activeBar);

    if (contentIndex >= 0) {
        contentArea->setCurrentIndex(contentIndex);
        logTabClick(contentIndex, type);
    }

};

void FlexibleTabWidget::handleCurrentChange(QTabBar* activeBar,int newIndex, const QString &type){

    // 计算内容区域索引
    int contentIndex = getIndex(activeBar);

    if (contentIndex >= 0) {
        contentArea->setCurrentIndex(contentIndex);
        logTabChange(contentIndex,newIndex, type);
    }
}

int FlexibleTabWidget::getIndex(QTabBar* activeBar){
    int contentIndex = -1;
    if (activeBar == topBar) {
        contentIndex = activeBar->currentIndex();
    } else if (activeBar == middleBar) {
        contentIndex = topBar->count() + activeBar->currentIndex();
    } else if (activeBar == bottomBar) {
        contentIndex = topBar->count() + middleBar->count() + activeBar->currentIndex();
    }
    return contentIndex;
}

// 添加顶部标签（无图标）
int FlexibleTabWidget::addTopTab(QWidget *widget, const QString &label)
{
    const int insertPos = topBar->count();
    contentArea->insertWidget(insertPos, widget);
    topBar->addTab(label);
    qDebug() << "FlexibleTabWidget - add TopTab: " << insertPos;
    return insertPos;
}

// 添加顶部标签（带图标）
int FlexibleTabWidget::addTopTab(QWidget *widget, const QIcon& icon, const QString &label)
{
    const int insertPos = topBar->count();
    contentArea->insertWidget(insertPos, widget);
    topBar->addTab(icon, label);
    qDebug() << "FlexibleTabWidget - add TopTab: " << insertPos;
    return insertPos;
}

// 添加中间标签（无图标）
int FlexibleTabWidget::addMiddleTab(QWidget *widget, const QString &label)
{

    const int insertPos = topBar->count() + middleBar->count();
    contentArea->insertWidget(insertPos, widget);
    middleBar->addTab(label);
    qDebug() << "FlexibleTabWidget - add middleTab: " << insertPos;
    return insertPos;
}

// 添加中间标签（带图标）
int FlexibleTabWidget::addMiddleTab(QWidget *widget, const QIcon& icon, const QString &label)
{
    const int insertPos = topBar->count() + middleBar->count();
    contentArea->insertWidget(insertPos, widget);
    middleBar->addTab(icon, label);
    qDebug() << "FlexibleTabWidget - add middleTab: " << insertPos;
    return insertPos;
}

// 添加底部标签（无图标）
int FlexibleTabWidget::addBottomTab(QWidget *widget, const QString &label)
{
    const int insertPos = topBar->count() + middleBar->count() + bottomBar->count();
    contentArea->insertWidget(insertPos, widget);
    bottomBar->addTab(label);
    qDebug() << "FlexibleTabWidget - add bottomTab: " << insertPos;
    return insertPos;
}

// 添加底部标签（带图标）
int FlexibleTabWidget::addBottomTab(QWidget *widget, const QIcon& icon, const QString &label)
{
    const int insertPos = topBar->count() + middleBar->count() + bottomBar->count();
    contentArea->insertWidget(insertPos, widget);
    bottomBar->addTab(icon, label);
    qDebug() << "FlexibleTabWidget - add bottomTab: " << insertPos;
    return insertPos;
}

// 重写原生addTab（默认添加到顶部）
int FlexibleTabWidget::addTab(QWidget *widget, const QString &label)
{
    return addTopTab(widget, label);
}

// 重写原生addTab（默认添加到顶部）
int FlexibleTabWidget::addTab(QWidget *widget, const QIcon& icon, const QString &label)
{
    return addTopTab(widget, icon, label);
}

// 实现样式设置方法
void FlexibleTabWidget::setTabPosition(QTabWidget::TabPosition position)
{
    m_tabPos = position;
    m_autoAdjust = false;
    updateTabBarsShape();
}

void FlexibleTabWidget::setTabShape(QTabWidget::TabShape shape)
{
    m_tabShape = shape;
    updateTabBarsShape();
}

void FlexibleTabWidget::setElideMode(Qt::TextElideMode mode)
{
    topBar->setElideMode(mode);
    middleBar->setElideMode(mode);
    bottomBar->setElideMode(mode);
}

void FlexibleTabWidget::setUsesScrollButtons(bool useButtons)
{
    topBar->setUsesScrollButtons(useButtons);
    middleBar->setUsesScrollButtons(useButtons);
    bottomBar->setUsesScrollButtons(useButtons);
}

// 形状计算逻辑
QTabBar::Shape FlexibleTabWidget::getActualShape() const
{
    if(m_autoAdjust){
        const bool vertical = height() > width();
        const QTabWidget::TabPosition pos = vertical ? QTabWidget::West : QTabWidget::North;
        return (m_tabShape == QTabWidget::Triangular)
                   ? static_cast<QTabBar::Shape>(QTabBar::TriangularWest + pos)
                   : static_cast<QTabBar::Shape>(QTabBar::RoundedWest + pos);
    }

    const int base = m_tabShape == QTabWidget::Triangular
                         ? QTabBar::TriangularNorth
                         : QTabBar::RoundedNorth;
    return static_cast<QTabBar::Shape>(base + m_tabPos);
}

// 更新所有标签栏形状
void FlexibleTabWidget::updateTabBarsShape()
{
    const QTabBar::Shape shape = getActualShape();
    topBar->setShape(shape);
    middleBar->setShape(shape);
    bottomBar->setShape(shape);
}

void FlexibleTabWidget::logTabChange(int index, int newidex,  const QString &tabType)
{
    QString currentTime = QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss");
    QString logMessage = QString("Time: %1 | Tab Clicked - Type: %2, CurrentIndex: %3, NewIndex: %4")
                             .arg(currentTime)
                             .arg(tabType)
                             .arg(index)
                             .arg(newidex);

    // 输出到控制台
    qDebug() << qPrintable(logMessage);

}

void FlexibleTabWidget::logTabClick(int index, const QString &tabType)
{
    QString currentTime = QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss");
    QString logMessage = QString("Time: %1 | Tab Clicked - Type: %2, CurrentIndex: %3")
                             .arg(currentTime)
                             .arg(tabType)
                             .arg(index);

    // 输出到控制台
    qDebug() << qPrintable(logMessage);

}

// 响应窗口大小变化
void FlexibleTabWidget::resizeEvent(QResizeEvent *event)
{
    if(m_autoAdjust){
        updateTabBarsShape();
    }
    QTabWidget::resizeEvent(event);
}

