#!/usr/bin/env perl
use Dancer2;
use LWP::UserAgent ();
use MIME::Base64;
use Switch;
use Digest::MD5 qw(md5_hex);

get '/image-inline/' => sub {
    delayed {
        my $url = query_parameters->get('url');

        if ( !$url ) {
            status 400;
            content "Missing url parameter";
            done;
            return;
        }

        response_header 'Content-Type' => 'text/plain';
        flush;
        print "URL\t$url\n";

        my $file_name = md5_hex($url);
        if ( -e "db/$file_name" ) {
            print "CACHE\t$url\n";
            my $content = do {
                local $/ = undef;
                open my $fh, "<", "db/$file_name";
                <$fh>;
            };
            content $content;
            done;
        }
        else {
            print "FETCH\t$url\n";

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

                mkdir "db" unless -d "db";

                open my $fh, ">", "db/$file_name";
                print $fh $data;
                close $fh;

                content $data;
            }
            else {
                status 500;
                content $response->status_line;
            }
            done;
        }
    }
};

start;
