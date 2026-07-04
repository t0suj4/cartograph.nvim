#include "thing_handler.h"

void ThingHandler::RegisterMessages() {
  web_ui()->RegisterMessageCallback(
      "getThing",
      base::BindRepeating(&ThingHandler::HandleGetThing,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "ghostMessage",
      base::BindRepeating(&Missing::Nowhere, base::Unretained(this)));
}

void ThingHandler::HandleGetThing(const base::Value::List& args) {
  reply(args);
}

void reply(const base::Value::List& args) {}
