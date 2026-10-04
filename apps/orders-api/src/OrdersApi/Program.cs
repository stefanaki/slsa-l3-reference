using System.Reflection;
using OrdersApi;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var version = typeof(Program).Assembly
    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "unknown";

app.MapGet("/healthz", () => Results.Ok(new { status = "ok" }));
app.MapGet("/orders", () => Results.Ok(SampleOrders.All));
app.MapGet("/version", () => Results.Ok(new { version }));

app.Run();
