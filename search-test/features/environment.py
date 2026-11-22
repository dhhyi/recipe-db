from search_support import REST, SearchSession, request


def before_all(context):
    status, raw, _ = request(REST + "/recipes", "DELETE")
    assert status == 204, (status, raw)
    client = SearchSession()
    client.finish_rebuild(client.start_rebuild())


def before_scenario(context, scenario):
    context.client = SearchSession()
    context.recipes = {}
    context.add_cleanup(context.client.cleanup)
