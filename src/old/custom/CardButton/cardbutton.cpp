#include "cardbutton.h"

CardButton::CardButton(const QString &title, const QString &subtitle, QWidget *parent)
    : QWidget{parent}
{
    // 主布局
    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(5);

    MainSubTitle *titlesLayout = new MainSubTitle(title, subtitle, this);

    // 组合框
    button = new QPushButton(this);
    button->setStyleSheet("QPushButton { padding: 5px; }");

    // 添加到布局
    layout->addWidget(titlesLayout);
    layout->addWidget(button);

}
