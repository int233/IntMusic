#include "index.h"

TabIndex::TabIndex(QWidget *parent)
    : QWidget{parent}
{
    IndexScrollContent = new QScrollArea(this);
    IndexScrollContent->setWidgetResizable(true);

    IndexContent = new QWidget();
    IndexScrollContent->setWidget(IndexContent);
    QVBoxLayout *IndexContentLayout = new QVBoxLayout(IndexContent);

    // 最多播放部分
    MostPlayed = new QWidget();
    QVBoxLayout *MostPlayedLayout = new QVBoxLayout(MostPlayed);
    MostPlayedTitle = new QLabel("最多播放", MostPlayed);
    MostPlayedCards = new QScrollArea(MostPlayed);
    MostPlayedCards->setWidgetResizable(true);
    MostPlayedCardList = new QListWidget();
    MostPlayedCards->setWidget(MostPlayedCardList);
    MostPlayedLayout->addWidget(MostPlayedTitle);
    MostPlayedLayout->addWidget(MostPlayedCards);


    // 最近添加部分
    ResentlyAdded = new QWidget();
    QVBoxLayout *ResentlyAddedLayout = new QVBoxLayout(ResentlyAdded);
    ResentlyAddedTitle = new QLabel("最近添加", ResentlyAdded);
    ResentlyAddedCards = new QScrollArea(ResentlyAdded);
    ResentlyAddedCards->setWidgetResizable(true);
    ResentlyAddedCardList = new QListWidget();
    ResentlyAddedCards->setWidget(ResentlyAddedCardList);
    ResentlyAddedLayout->addWidget(ResentlyAddedTitle);
    ResentlyAddedLayout->addWidget(ResentlyAddedCards);



    QVBoxLayout *IndexLayout = new QVBoxLayout(this);
    IndexLayout->addWidget(IndexScrollContent);
    IndexContentLayout->addWidget(MostPlayed);
    IndexContentLayout->addWidget(ResentlyAdded);
}
