package Zadm::Image::OmniOSus;
use Mojo::Base 'Zadm::Image::OmniOS';

has baseurl  => 'https://us-west.mirror.omniosce.org/downloads/media';
has index    => sub { shift->SUPER::baseurl . '/img-us-west.json' };
# overriding the provider as perl does not allow hyphens in package names
has provider => 'omnios-us';

1;
