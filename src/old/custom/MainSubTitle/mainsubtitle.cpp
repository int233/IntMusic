#include "mainsubtitle.h"

MainSubTitle::MainSubTitle(const QString &title, const QString &subtitle, QWidget *parent)
    : QWidget{parent}
{
    QVBoxLayout *layout = new QVBoxLayout(this);

    // 标题
    titleLabel = new QLabel(title, this);
    titleLabel->setStyleSheet("font-size: 16px; font-weight: bold;");

    // 副标题
    subtitleLabel = new QLabel(subtitle, this);
    subtitleLabel->setStyleSheet("font-size: 12px; color: gray;");

    layout->addWidget(titleLabel);
    layout->addWidget(subtitleLabel);
}
