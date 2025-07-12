#ifndef FLEXIBLETABWIDGET_H
#define FLEXIBLETABWIDGET_H

#include <QTabWidget>
#include <QTabBar>
#include <QStackedWidget>
#include <QDebug>
#include <QDateTime>

class FlexibleTabWidget : public QTabWidget
{
    Q_OBJECT
public:
    explicit FlexibleTabWidget(QWidget *parent = nullptr);

    // 顶部标签操作
    int addTopTab(QWidget *widget, const QString &label);
    int addTopTab(QWidget *widget, const QIcon& icon, const QString &label);

    // 中间标签操作
    int addMiddleTab(QWidget *widget, const QString &label);
    int addMiddleTab(QWidget *widget, const QIcon& icon, const QString &label);

    // 底部标签操作
    int addBottomTab(QWidget *widget, const QString &label);
    int addBottomTab(QWidget *widget, const QIcon& icon, const QString &label);

    // 重写原生addTab
    int addTab(QWidget *widget, const QString &label);
    int addTab(QWidget *widget, const QIcon& icon, const QString &label);

    void setTabPosition(QTabWidget::TabPosition position);
    void setTabShape(QTabWidget::TabShape shape);
    void setElideMode(Qt::TextElideMode mode);
    void setUsesScrollButtons(bool useButtons);

protected:
    void resizeEvent(QResizeEvent *event) override;

private:
    QTabBar *topBar;
    QTabBar *middleBar;
    QTabBar *bottomBar;
    QWidget *spacer;

    QStackedWidget *contentArea; // 独立内容区域

    bool m_autoAdjust = true;
    QTabWidget::TabPosition m_tabPos = QTabWidget::West;
    QTabWidget::TabShape m_tabShape = QTabWidget::Triangular;

    void updateTabBarsShape();
    QTabBar::Shape getActualShape() const;

    void updateTabConnections();
    int getIndex(QTabBar* activeBar);
    void handleCurrentChange(QTabBar* activeBar,int newIndex, const QString &type);
    void handleClicked(QTabBar* activeBar, const QString &type);

private slots:
    void logTabClick(int index,const QString &tabType);
    void logTabChange(int index, int newindex, const QString &tabType);

};

#endif // FLEXIBLETABWIDGET_H
