#ifndef ABSTRACTCOMMAND_H
#define ABSTRACTCOMMAND_H

#include <QStringList>
#include <QVariant>
#include <QMap>

class AbstractCommand {
public:
    virtual ~AbstractCommand() = default;
    virtual void execute(const QStringList& args) = 0;
    virtual QString name() const = 0;
    virtual QString description() const = 0;
};

#endif // ABSTRACTCOMMAND_H