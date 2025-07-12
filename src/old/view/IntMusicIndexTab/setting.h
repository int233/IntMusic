#ifndef SETTING_H
#define SETTING_H

#include <QWidget>
#include <QTabWidget>
#include <QVBoxLayout>
#include <QRadioButton>
#include <QGroupBox>
#include <QLineEdit>
#include <QPushButton>
#include <QFileDialog>
#include <QLabel>
#include <QStandardPaths>
#include <QApplication>
#include <QDir>

#include "app/view/Setting/settingcommon.h"
#include "app/view/Setting/settingconfig.h"

class TabSetting : public QWidget
{
    Q_OBJECT
public:
    explicit TabSetting(QWidget *parent = nullptr);

private:
    void updatePathDisplay();

    SettingCommon *tabSettingTabCommon;

private slots:


signals:
};


#endif // SETTING_H
