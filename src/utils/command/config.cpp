#include "config.h"



void ConfigCommand::execute(const QStringList& args) {
    if (args.isEmpty() || args.first() == "help") {
        m_window->appendLogMessage("Usage: config <subcommand> [options]");
        m_window->appendLogMessage("Subcommands:");
        m_window->appendLogMessage("show - Show current configuration.");
        m_window->appendLogMessage("set <key> <value> - Set a configuration key to a value.");
        m_window->appendLogMessage("migrate <new_path> - Migrate configuration to a new path.");
        
        return;
    }

    QStringList sub_args = args;
    QString sub_command = sub_args.takeFirst().toLower();

    if (sub_command == "show") {
        // Show current configuration
        m_window->appendLogMessage("Current configuration:");
        QSettings* m_settings = m_configManager.get_settings();
        // show all settings
        QStringList keys = m_settings->allKeys();
        for (const QString &key : keys) {
            QVariant value = m_settings->value(key);
            m_window->appendLogMessage(QString("%1: %2").arg(key, value.toString()));
        }
    } else {
        m_window->appendLogMessage(QString("Unknown subcommand '%1'").arg(sub_command));
    }
}