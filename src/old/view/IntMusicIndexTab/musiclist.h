#ifndef MUSICLIST_H
#define MUSICLIST_H

#include <QWidget>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLineEdit>
#include <QComboBox>
#include <QCheckBox>
#include <QListWidget>
#include <QScrollArea>

#include "app/view/MusicListView/musiclistview.h"

class TabMusicList : public QWidget
{
    Q_OBJECT
public:
    explicit TabMusicList(QWidget *parent = nullptr);

private:
    QVBoxLayout *mainLayout;
    QScrollArea *scrollArea;
    QWidget *scrollContent;
    QVBoxLayout *scrollLayout;
    QWidget *searchAndSortWidget;
    QHBoxLayout *searchAndSortLayout;
    QLineEdit *searchBox;
    QComboBox *sortTypeComboBox;
    QCheckBox *reverseOrderCheckBox;
    QListWidget *musicListWidge;


signals:

private slots:
    void onSearchTextChanged(const QString &text);
    void onSortTypeChanged(int index);
    void onReverseOrderChanged(int state);
};



#endif // MUSICLIST_H
