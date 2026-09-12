#!/usr/bin/env perl
use Dancer2;
use LWP::UserAgent ();
use MIME::Base64;
use Switch;
use Digest::MD5 qw(md5_hex);
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json);

# get database location from environment
my $db = $ENV{DATA_LOCATION} || "db";
print "Database location: $db\n";

my $verbose = $ENV{VERBOSE} || 0;

make_path($db);

# RFC 9457 Problem Details body, mirroring the recipes service's error shape.
sub send_problem {
    my ( $status, $title, $detail, $code ) = @_;
    status $status;
    content_type 'application/problem+json';
    content encode_json(
        {
            type   => "about:blank",
            title  => $title,
            status => $status,
            detail => $detail,
            code   => $code,
        }
    );
}

get '/health' => sub {
    status 204;
};

get '/image-inline/' => sub {
    delayed {
        my $url = query_parameters->get('url');

        if ( !$url ) {
            send_problem( 400, "Bad Request", "Missing url parameter",
                "missing-query-param" );
            done;
            return;
        }

        if ($verbose) {
            print "URL\t$url\n";
        }

        my $file_name = md5_hex($url);
        if ( -e "$db/$file_name" ) {
            if ($verbose) {
                print "CACHE\t$url\n";
            }
            my $content = do {
                local $/ = undef;
                open my $fh, "<", "$db/$file_name";
                <$fh>;
            };
            content_type 'text/plain';
            content $content;
            done;
        }
        else {
            if ($verbose) {
                print "FETCH\t$url\n";
            }

            my $ext = $url =~ s/.*\.//r;
            switch ($ext) {
                case "png"  { $ext = "image/png" }
                case "jpg"  { $ext = "image/jpeg" }
                case "jpeg" { $ext = "image/jpeg" }
                case "gif"  { $ext = "image/gif" }
                case "bmp"  { $ext = "image/bmp" }
                case "webp" { $ext = "image/webp" }
                else        { $ext = "image/x-icon" }
            }

            # get image bytes
            my $ua       = LWP::UserAgent->new;
            my $response = $ua->get($url);

            if ( $response->is_success ) {
                my $content = $response->decoded_content;
                my $encoded = encode_base64($content) =~ s/\n//gr;

                my $data = "data:$ext;base64,$encoded";

                open my $fh, ">", "$db/$file_name";
                print $fh $data;
                close $fh;

                content_type 'text/plain';
                content $data;
            }
            else {
                send_problem( 500, "Internal Server Error",
                    $response->status_line, "fetch-error" );
            }
            done;
        }
    }
};

start;
