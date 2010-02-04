
require 'rexml/document'
require 'parser'

module CamelName
  # Create a camel case name where all leading uppercase letters
  # are downcased and the last is left upper. If the name is all
  # upper case, downcase the whole name.
  def camel(v)
    value = v.to_s
    if value.upcase == value
      value.downcase
    else
      value.gsub(/^[A-Z]*/) do |v|
        if v.length > 1
          v[0...-1].downcase + v[-1].chr
        else
          v.downcase
        end
      end
    end
  end

  # Create the type name with optional leading mtc: if necessary.
  # Do not add Type if Type is already at the end of the name.
  def type_name(value, withNs)
    value += 'Type' unless value =~ /Type(s)?$/o
    value = "#{value}" if withNs
    value
  end

  def camel_name
    camel(@name)
  end

  def camel_type
    camel(@type.to_s)
  end

  def name_as_xsd_type(withNs = false)
    type_name(@name.to_s, withNs)
  end

  def type_as_xsd_type(withNs = false)
    type_name(@type.to_s, withNs)
  end

  def parent_as_xsd_type(withNs = false)
    type_name(@parent.to_s, withNs)
  end
end

class Schema
  def generate_xsd
    doc = REXML::Document.new
    doc << REXML::XMLDecl.new("1.0", "UTF-8")
    
    # Root schema node.
    root = REXML::Element.new('xs:schema')
    root.add_namespace('xs', 'http://www.w3.org/2001/XMLSchema')
    root.add_namespace(@urn)
    root.add_namespace(@namespace, @urn)
    root.add_attribute('targetNamespace',@urn)
    root.add_attribute('elementFormDefault', "qualified")
    root.add_attribute('attributeFormDefault', "unqualified")
    doc << root
            
    element = REXML::Element.new('xs:element')
    top = @type_map[@top]
    element.add_attribute('name', top.name.to_s)
    element.add_attribute('type', "#{top.name_as_xsd_type}")
    anno = REXML::Element.new('xs:annotation')
    docs = REXML::Element.new('xs:documentation')
    docs.text = top.annotation
    anno << docs
    element << anno
    root << element
    
    @types.each { |type| type.build_hierarchy }
    @types.each { |type| type.resolve }
    @types.each do |type|
      elements = type.generate_xsd
      elements.each { |e| root << e }
    end

    doc
  end

  
  class Type
    include CamelName
  end

  class Element

    def simple?
      value = @members.find { |m| m.is_value? }
      return true if value
      return true if @parent.nil? and !abstract?
      resolve_parent.simple? if @parent
      false
    end

    def create_complex_type
      # Start out with a complex type.
      complex_type = REXML::Element.new('xs:complexType')
      complex_type.add_attribute('name', name_as_xsd_type)
      
      anno = REXML::Element.new('xs:annotation')
      docs = REXML::Element.new('xs:documentation')
      docs.text = @annotation
      anno << docs
      complex_type << anno
      
      # Check for a pure abstract class.
      complex_type.add_attribute('abstract', 'true') if abstract?

      complex_type
    end

    # Create a simple extension where we only have one member.
    def create_type_single_element
      # Check of the special case when we have only one member
      member, = @elems
      
      # If this is just a choice
      if Choice === member and !subtype?
        # Start out with a complex type.
        complex_type = create_complex_type
        complex_type << member.generate_xsd
        @attr_elem = complex_type
      elsif member.is_value?
        # Start out with a complex type.
        complex_type = create_complex_type
        
        # If this is a complex type with just a value, create a simple content
        # that extends the parent or the type specified in the element.
        simple_content = REXML::Element.new('xs:simpleContent')
        type = member.resolve_type

        if @parent
          if @members.length == 1
            @attr_elem = extension = REXML::Element.new('xs:restriction')
          else
            @attr_elem = extension = REXML::Element.new('xs:extension')
          end
          extension.add_attribute('base', parent_as_xsd_type(true))
          
          # Since extension by restriction does not allow us
          # to restrict the content based on a simple type,
          # we pull the facets into the schema here. This is
          # not ideal, but allows us to skip an extra level
          # of indirection.
          if BasicType === type
            type.add_facet(extension)
          elsif ControlledVocabulary === type
            type.add_enumeration(extension)
          end
        else
          # Value is a special flag for a simple content object.
          # Take the type and copy as the parent for the extension.
          type = member.resolve_type
          @attr_elem = extension = REXML::Element.new('xs:extension')
          extension.add_attribute('base', type.name_as_xsd_type(true))
        end
        
        simple_content << extension
        complex_type << simple_content
      else
        # Passed all the special cases, let's treat this like a
        # multimember complex type
        complex_type = create_type_multiple_elements
      end

      complex_type
      
    rescue
      puts "Error on: #{self.name}"
      raise
    end

    def create_type_no_elements
      # If there are no elements.
      complex_type = create_complex_type

      parent = resolve_parent
      if simple? or (parent and parent.simple?)
        # puts "Simple type: #{@name}"
        # Always use simple content if no elements are specified. This
        # is special cased for abstract inheritance types.
        simple_content = REXML::Element.new('xs:simpleContent')
        extension = REXML::Element.new('xs:extension')
        @attr_elem = extension
        
        # If there is a parent, subclass the parent, otherwise
        # Make this a subclass of simple type.
        if @parent
          extension.add_attribute('base', parent_as_xsd_type(true))
        else
          extension.add_attribute('base', 'xs:string')
        end
        simple_content << extension
        complex_type << simple_content
      elsif @parent
        complex_content = REXML::Element.new('xs:complexContent')
        extension = REXML::Element.new('xs:extension')
        extension.add_attribute('base', parent_as_xsd_type(true))
        @attr_elem = extension
        complex_content << extension
        complex_type << complex_content
      else
        @attr_elem = complex_type        
      end
      complex_type
      
    rescue
      puts $!
      puts "Error in #{self}"
      raise
    end

    # If we have more than one element or if there wasn't a choice or
    # just a single value, add some complex content.
    def create_type_multiple_elements
      # Start out with a complex type.
      complex_type = create_complex_type
      @attr_elem = complex_type
      
      # This code does not always work since it is not possible
      # extend complex content from simple content. The
      # abstract base class is always simple content.
      if @parent
        # check if the parent has the same set of members
        complex_content = REXML::Element.new('xs:complexContent')
        if resolve_parent.restriction?(self)
          extension = REXML::Element.new('xs:restriction')
        else
          extension = REXML::Element.new('xs:extension')
        end
        extension.add_attribute('base', parent_as_xsd_type(true))
        @attr_elem = extension
        complex_content << extension
        complex_type << complex_content
      end

      # Add the elements to the sequence.
      sequence = REXML::Element.new('xs:sequence')
      @elems.each do |element|
        sequence << element.generate_element
      end
      (extension || complex_type) << sequence

      complex_type
    end

    def add_attributes
      # Add the attribute declarations.
      @attrs.each do |m|
        m.generate_attribute(@attr_elem)
      end
    end

    def create_substitution_group
      # Add an element with a substitution group for this type. The
      # substitution group will allow one level of subclassing below
      # the abstract level. This may need to be extended later.
      element = REXML::Element.new('xs:element')
      element.add_attribute('abstract', 'true') if abstract?
      element.add_attribute('name', @name.to_s)
      element.add_attribute('type', name_as_xsd_type(true))
      if subtype? and abstract_parent?
        element.add_attribute('substitutionGroup', "#{@parent}")
      end
      
      # Annotate again for XML Spy documentation.
      anno = REXML::Element.new('xs:annotation')
      docs = REXML::Element.new('xs:documentation')
      docs.text = @annotation
      anno << docs
      element << anno

      element
    end
    
    def generate_xsd
      collect_members
      # puts "#{@name}: #{@elems.length} #{@attrs.length}"
      complex_type = if @elems.length == 0
        create_type_no_elements
      elsif @elems.length == 1
        create_type_single_element
      else # @elems.length > 0
        create_type_multiple_elements
      end

      add_attributes

      elements = [complex_type]

      # Check for abstract superclasses with derrived children or children
      # with abstract parents.
      if abstract_parent? or (abstract? and has_subtypes?)
        elements << create_substitution_group
      end

      elements

    rescue
      puts "Error Generating: #{@name}"
      raise
    end
    
    def collect_members
      # First split the members into groups of elements and attributes
      @attrs, @elems = @members.partition { |ele| ele.attribute? }
    end
  end
  
  # Basic type extension.
  class BasicType
    # Add the facet onto a restriction.
    def add_facet(restriction)
      if @pattern
        restriction.add_element('xs:pattern', {'value' => @pattern})
      end
      if @facet
        facets = @facet.split(';')
        facets.map { |f| f.split('=') }.each do |f, v|
          case f
          when 'max'
            restriction.add_element('xs:maxLength', {'value' => v})
            
          when 'min'
            restriction.add_element('xs:minLength', {'value' => v})
            
          when 'len'
            restriction.add_element('xs:length', {'value' => v})
            
          else
            raise "Can not gen facet: #{f} = #{v}"
          end
        end
      end
    end

    def generate_xsd
      # Basic types are all simple types.
      simple_type = REXML::Element.new('xs:simpleType')
      simple_type.add_attribute('name', name_as_xsd_type)
      anno = REXML::Element.new('xs:annotation')
      docs = REXML::Element.new('xs:documentation')
      docs.text = @annotation
      anno << docs
      simple_type << anno

      restriction = REXML::Element.new('xs:restriction')
      restriction.add_attribute('base', "xs:#{@parent}")
      add_facet(restriction)
      simple_type << restriction
      
      [simple_type]
    rescue
      puts "Error on: #{self.inspect}"
      raise
    end
  end
  
  class Member
    include CamelName

    def add_occurrence(element)
      case @occurrence
      when Fixnum
        element.add_attribute('minOccurs', @occurrence.to_s)

      when Range
        element.add_attribute('minOccurs', @occurrence.first.to_s)
        if @occurrence.last == INF
          element.add_attribute('maxOccurs', 'unbounded')
        else
          element.add_attribute('maxOccurs', @occurrence.last.to_s)
        end
      end
    end

    def generate_element
      # Create the element.
      element = REXML::Element.new('xs:element')
      
      if @default
        element.add_attribute('default', @default.to_s)
      end
      
      # If this is an abstract object with a parent or if it
      # has subclasses, we will need to create substitution groups
      # so add a reference instead of a name and type.
      type = resolve_type
      if references_abstract?
        element.add_attribute('ref', "#{type.name}")
      else
        element.add_attribute('name', @name.to_s)
        element.add_attribute('type', type_as_xsd_type(true))
        
        # Add annotation to make sure the element is documented. This is not
        # necessary for references.
        if type
          #puts "#{name} #{type.name}"
          anno = REXML::Element.new('xs:annotation')
          docs = REXML::Element.new('xs:documentation')
          docs.text = @annotation
          anno << docs
          element << anno
        end
      end
      
      # Check for an occurrence.
      add_occurrence(element)
      element
    end

    def generate_attribute(element)
      attrs = {'name' => camel_name, 'type' => type_as_xsd_type(true)}
      # Always specify the use of the attribute.
      # puts "#{@name} #{@occurrence.inspect}"
      if @occurrence.nil? || @occurrence == 1
        attrs['use'] = 'required'
      else
        attrs['use'] = 'optional'
      end
      
      if @default
        attrs['default'] = @default
      end
      
      # If the extension was specified, add to the extension otherwise
      # add directly tot he complex type.
      element.add_element('xs:attribute', attrs)
    end

    def generate_xsd
      # At the top level, just generate the member. 
      generate_element
    end
  end

  class Choice
    def generate_xsd
      choice = REXML::Element.new('xs:choice')
      add_occurrence(choice)

      @members.each do |mem|
        choice << mem.generate_xsd
      end

      choice
    end
    alias generate_element generate_xsd
  end
  
  class ControlledVocabulary
    def add_enumeration(restriction)
      # Special case for a single empty type
      @values.each do |val|
        restriction.add_element('xs:enumeration', {'value' => val.name})
      end
    end

    def generate_xsd
      # Enumerated values are always NMTOKEN value restricted by the
      # values. 
      simple_type = REXML::Element.new('xs:simpleType')
      simple_type.add_attribute('name', name_as_xsd_type)
      anno = REXML::Element.new('xs:annotation')
      docs = REXML::Element.new('xs:documentation')
      docs.text = @annotation
      anno << docs
      simple_type << anno

      restriction = REXML::Element.new('xs:restriction')

      nmtoken = @values.map do |mem|
        mem.name =~ /[^A-Z0-9]/i
      end.all?
      
      # Special case for an empty pattern that needs to be a xs:string.
      if !nmtoken or (@values.length == 1 and @values.first.name.empty?)
        restriction.add_attribute('base', 'xs:string')
      else
        restriction.add_attribute('base', 'xs:NMTOKEN')
      end

      if @parent and (parent_type = @schema.type(@parent))
        parent_type.add_enumeration(restriction)
      end

      # Add the enumerations.
      add_enumeration(restriction)
      simple_type << restriction
      
      [simple_type]
    end
  end
end
