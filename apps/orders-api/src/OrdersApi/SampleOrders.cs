namespace OrdersApi;

public sealed record Order(int Id, string Customer, string Item, int Quantity, decimal Total);

public static class SampleOrders
{
    public static IReadOnlyList<Order> All { get; } =
    [
        new(1, "Acme Corp", "Widget", 3, 29.97m),
        new(2, "Globex", "Gadget", 1, 49.00m),
        new(3, "Initech", "Stapler", 12, 95.40m),
    ];
}
