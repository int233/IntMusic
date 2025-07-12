#ifndef MAINSUBTITLE_H
#define MAINSUBTITLE_H

#include <QWidget>
#include <QLabel>
#include <QVBoxLayout>

class MainSubTitle : public QWidget
{
    Q_OBJECT
public:
    explicit MainSubTitle(const QString &title, const QString &subtitle, QWidget *parent = nullptr);

private:
    QLabel *titleLabel;    // 标题
    QLabel *subtitleLabel; // 副标题

signals:
};

#endif // MAINSUBTITLE_H
