#ifndef CARDCOMBO_H
#define CARDCOMBO_H

#include <QWidget>
#include <QLabel>
#include <QComboBox>
#include <QVBoxLayout>

#include <app/custom/MainSubTitle/mainsubtitle.h>

class CardCombo : public QWidget
{
    Q_OBJECT
public:
    explicit CardCombo(const QString &title, const QString &subtitle, QWidget *parent = nullptr);

    QString currentSelection() const;
    void setOptions(const QStringList &options);

    QComboBox* getComboBox() const { return comboBox; }
    void setCurrentIndex(int index);

private:
    QLabel *titleLabel;    // 标题
    QLabel *subtitleLabel; // 副标题
    QComboBox *comboBox;   // 组合框

signals:
};

#endif // CARDCOMBO_H
