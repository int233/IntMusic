#ifndef TABINDEX_H
#define TABINDEX_H

#include <QWidget>
#include <QScrollArea>
#include <QVBoxLayout>
#include <QLabel>
#include <QListWidget>

class TabIndex : public QWidget
{
    Q_OBJECT
public:
    explicit TabIndex(QWidget *parent = nullptr);

private:
    QScrollArea *IndexScrollContent;
    QWidget *IndexContent;
    QWidget *MostPlayed;
    QLabel *MostPlayedTitle;
    QScrollArea *MostPlayedCards;
    QListWidget *MostPlayedCardList;
    QWidget *ResentlyAdded;
    QLabel *ResentlyAddedTitle;
    QScrollArea *ResentlyAddedCards;
    QListWidget *ResentlyAddedCardList;


signals:
};

#endif // TABINDEX_H
