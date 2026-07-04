namespace = "shop"


def urls():
    return [
        path("", index_view, name="index"),
        path("b/", basket_view, name="basket"),
        path("b/<int:pk>/", basket_view, name="basket"),
        path("dead/", dead_view, name="never-named"),
    ]


def redirect_home(request):
    return redirect(reverse("shop:index"))
