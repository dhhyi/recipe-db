from search_support import SearchSession


def before_scenario(context, scenario):
    context.client = SearchSession()
    context.recipes = {}
    context.add_cleanup(context.client.cleanup)
