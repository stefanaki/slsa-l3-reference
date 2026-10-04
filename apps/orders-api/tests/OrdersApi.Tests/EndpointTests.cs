using System.Net;
using System.Net.Http.Json;
using System.Reflection;
using Microsoft.AspNetCore.Mvc.Testing;
using OrdersApi;

namespace OrdersApi.Tests;

public sealed class EndpointTests(WebApplicationFactory<Program> factory)
    : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client = factory.CreateClient();

    [Fact]
    public async Task Healthz_ReturnsOk()
    {
        var response = await _client.GetAsync("/healthz", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<HealthResponse>(TestContext.Current.CancellationToken);
        Assert.Equal("ok", body?.Status);
    }

    [Fact]
    public async Task Orders_ReturnsSampleOrders()
    {
        var orders = await _client.GetFromJsonAsync<List<Order>>("/orders", TestContext.Current.CancellationToken);

        Assert.NotNull(orders);
        Assert.Equal(SampleOrders.All, orders);
    }

    [Fact]
    public async Task Version_ReturnsAssemblyInformationalVersionWithoutCommitSuffix()
    {
        var expected = typeof(Program).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion;

        var body = await _client.GetFromJsonAsync<VersionResponse>("/version", TestContext.Current.CancellationToken);

        Assert.Equal(expected, body?.Version);
        Assert.DoesNotContain("+", body?.Version);
    }

    private sealed record HealthResponse(string Status);

    private sealed record VersionResponse(string Version);
}
