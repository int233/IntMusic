#ifndef CARDPATHSELECT_H
#define CARDPATHSELECT_H

#include <QWidget>
#include <QLabel>
#include <QVBoxLayout>
#include <QPushButton>
#include <QFileDialog>
#include <QListWidget>
#include <QHBoxLayout>
#include <QMessageBox>
#include <QDebug>

#include <app/custom/MainSubTitle/mainsubtitle.h>
#include "app/util/Config/configmanager.h"

class CardPathSelect : public QWidget
{
    Q_OBJECT
public:
    explicit CardPathSelect(const QString &title, const QString &subtitle, QWidget *parent = nullptr);
    void loadPaths();

private:

    QListWidget *pathListWidget;
    QPushButton *addButton;
    // void resizeEvent(QResizeEvent *event);

    ConfigManager &configManager;
    QSettings *intSetting;

    void addPathToList(const QString &path);
    void savePathsToConfig(const QStringList &paths);

signals:
    void pathsUpdated(const QStringList &paths);


private slots:
    void onAddButtonClicked();
    void onRemoveButtonClicked();
};

#endif // CARDPATHSELECT_H
