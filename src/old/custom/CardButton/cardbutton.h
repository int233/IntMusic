#ifndef CARDBUTTON_H
#define CARDBUTTON_H

#include <QWidget>
#include <QLabel>
#include <QVBoxLayout>
#include <QPushButton>

#include <app/custom/MainSubTitle/mainsubtitle.h>

class CardButton : public QWidget
{
    Q_OBJECT
public:
    explicit CardButton(const QString &title, const QString &subtitle, QWidget *parent = nullptr);
    QPushButton* getPushButton() const { return button; }

private:
    QPushButton *button;

signals:
};

#endif // CARDBUTTON_H
