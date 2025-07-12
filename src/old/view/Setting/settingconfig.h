#ifndef SETTINGCONFIG_H
#define SETTINGCONFIG_H

#include <QWidget>
#include <QVBoxLayout>
#include <QTextEdit>
#include <QDebug>


#include "app/util/Config/configmanager.h"

class SettingConfig : public QWidget
{
    Q_OBJECT
public:
    explicit SettingConfig(QWidget *parent = nullptr);

    QSettings* intSetting;

    void updateConfigDisplay(QTextEdit *configDisplay);

signals:
};

#endif // SETTINGCONFIG_H
