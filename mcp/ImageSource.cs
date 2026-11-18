using System.Net;
using System.Net.Sockets;

namespace Mcp;

internal static class ImageSource
{
    public const string ClientName = "image-source";
    public const int MaxBytes = 10 * 1024 * 1024;

    private static readonly IPNetwork[] NonPublicIPv4 =
    [
        IPNetwork.Parse("0.0.0.0/8"), IPNetwork.Parse("10.0.0.0/8"),
        IPNetwork.Parse("100.64.0.0/10"), IPNetwork.Parse("127.0.0.0/8"),
        IPNetwork.Parse("169.254.0.0/16"), IPNetwork.Parse("172.16.0.0/12"),
        IPNetwork.Parse("192.0.0.0/24"), IPNetwork.Parse("192.0.2.0/24"),
        IPNetwork.Parse("192.88.99.0/24"), IPNetwork.Parse("192.168.0.0/16"),
        IPNetwork.Parse("198.18.0.0/15"), IPNetwork.Parse("198.51.100.0/24"),
        IPNetwork.Parse("203.0.113.0/24"), IPNetwork.Parse("224.0.0.0/3"),
    ];

    private static readonly IPNetwork GlobalIPv6 = IPNetwork.Parse("2000::/3");
    private static readonly IPNetwork[] SpecialIPv6 =
    [
        IPNetwork.Parse("2001::/23"), IPNetwork.Parse("2001:db8::/32"),
        IPNetwork.Parse("2002::/16"), IPNetwork.Parse("3fff::/20"),
    ];

    private static bool IsPublic(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6)
            address = address.MapToIPv4();
        return address.AddressFamily == AddressFamily.InterNetwork
            ? !NonPublicIPv4.Any(network => network.Contains(address))
            : GlobalIPv6.Contains(address) && !SpecialIPv6.Any(network => network.Contains(address));
    }

    public static SocketsHttpHandler CreateHandler(bool testing) => new()
    {
        UseProxy = false,
        UseCookies = false,
        ConnectCallback = async (context, cancellationToken) =>
        {
            var endpoint = context.DnsEndPoint;
            var fixture = testing && ((endpoint.Host == "traefik" && endpoint.Port == 3000)
                || (endpoint.Host == "fixtures" && endpoint.Port == 80));
            var addresses = await Dns.GetHostAddressesAsync(endpoint.Host, cancellationToken);
            // Connect to the checked address itself so redirects and fresh DNS lookups cannot bypass the check.
            foreach (var address in addresses.Where(address => fixture || IsPublic(address)))
            {
                var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                try
                {
                    await socket.ConnectAsync(address, endpoint.Port, cancellationToken);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch (SocketException)
                {
                    socket.Dispose();
                }
                catch
                {
                    socket.Dispose();
                    throw;
                }
            }

            throw new HttpRequestException("No permitted image source address could be reached.");
        },
    };
}
