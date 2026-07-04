from signals import product_viewed, receiver


class Basket:
    def all(self):
        return self.lines

    def add_line(self, line):
        self.lines.append(line)


@receiver(product_viewed)
def track_view(sender, **kwargs):
    return sender


def report(basket):
    return basket.all()
