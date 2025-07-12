#include "cardcombo.h"

CardCombo::CardCombo(const QString &title, const QString &subtitle, QWidget *parent)
    : QWidget{parent}
{
    // 主布局
    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(5);

    MainSubTitle *titlesLayout = new MainSubTitle(title, subtitle, this);

    // 组合框
    comboBox = new QComboBox(this);
    comboBox->setStyleSheet("QComboBox { padding: 5px; }");

    // 添加到布局
    layout->addWidget(titlesLayout);
    layout->addWidget(comboBox);
}

QString CardCombo::currentSelection() const {
    return comboBox->currentText();
}

void CardCombo::setOptions(const QStringList &options) {
    comboBox->clear();
    comboBox->addItems(options);
}

void CardCombo::setCurrentIndex(int index){
    comboBox->setCurrentIndex(index);
}
